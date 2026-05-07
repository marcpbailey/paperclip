# Feature: Wall-Clock Run Timeout for `openrouter-local`

## Objective

Add a configurable wall-clock timeout to `execute()` that aborts an in-flight
run after a specified number of seconds, returning a clean `timedOut: true`
result rather than hanging indefinitely.

## Motivation

`openrouter-local` runs its tool-calling loop in-process. Unlike subprocess
adapters (`codex-local`, `claude-local`) which can send SIGTERM to a child
process, the in-process model has no external kill mechanism. A hung OpenRouter
request, a slow model response, or a stalled `run_command` holds the run
indefinitely — subject only to per-tool timeouts, not any overall cap.

This spec addresses the most critical case: bounding total run duration. It
does not provide full pre-emptability (a `run_command` mid-execution will be
signalled but may take up to its own per-tool timeout to exit), but it ensures
`execute()` always returns within `timeoutSec` of the wall-clock timeout firing.

---

## Config field

```ts
// In agentConfigurationDoc:
// - timeoutSec (number, optional): maximum wall-clock seconds for a single run.
//   When exceeded, the run is aborted and returns timedOut: true. If absent or
//   0, no wall-clock timeout is applied (existing behaviour).
```

Consistent with `codex-local` and `claude-local` which expose the same field
name.

---

## Mechanism

### AbortController in `execute()`

When `timeoutSec > 0`, create an `AbortController` and schedule `abort()` after
the configured duration:

```ts
const controller = config.timeoutSec > 0
  ? new AbortController()
  : null;

const timeoutHandle = controller
  ? setTimeout(() => controller.abort(), Math.floor(asInt(config.timeoutSec, 0) * 1000))
  : null;

try {
  // ... tool loop ...
} catch (err) {
  if (isAbortError(err) || controller?.signal.aborted) {
    return {
      exitCode: 1,
      signal: null,
      timedOut: true,
      model: state.model,
      provider: state.provider,
      usage: { inputTokens: state.inputTokens, outputTokens: state.outputTokens },
      errorMessage: `Timed out after ${asInt(config.timeoutSec, 0)}s`,
      errorCode: "timeout",
    };
  }
  throw err;
} finally {
  if (timeoutHandle !== null) clearTimeout(timeoutHandle);
}
```

```ts
function isAbortError(err: unknown): boolean {
  return err instanceof Error && (err.name === "AbortError" || err.name === "TimeoutError");
}
```

### Signal passed to OpenAI client

The `AbortSignal` is forwarded to each `chat.completions.create()` call:

```ts
const completion = await client.chat.completions.create({
  model,
  messages,
  tools: ...,
  tool_choice: ...,
  ...(controller ? { signal: controller.signal } : {}),
});
```

When the signal fires mid-request, the OpenAI SDK throws an `AbortError`, which
the catch block above intercepts and converts to a `timedOut` result.

### Signal propagated through `ToolContext`

`ToolContext` in `src/server/tools.ts` gains an optional `signal` field:

```ts
export interface ToolContext {
  cwd: string;
  runCommandTimeoutSec: number;
  env?: Record<string, string>;
  signal?: AbortSignal;           // new — wall-clock abort signal
  // (Paperclip API fields added by native-api-tools-spec remain here)
}
```

`runShellCommand` gains an optional `signal` parameter and registers an abort
listener that sends SIGTERM to the child process:

```ts
export function runShellCommand(
  command: string,
  cwd: string,
  timeoutSec: number,
  extraEnv?: Record<string, string>,
  signal?: AbortSignal,           // new
): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", ["-lc", command], { ... });

    // Existing per-tool timeout (unchanged):
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); ... }, ...);

    // Wall-clock abort signal:
    const onAbort = () => {
      try { child.kill("SIGTERM"); } catch { /* ignore */ }
    };
    signal?.addEventListener("abort", onAbort, { once: true });

    child.on("close", (code, sig) => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      resolve({ exitCode: code, signal: sig, stdout, stderr, timedOut });
    });
    // ...
  });
}
```

`dispatchToolCall` passes `ctx.signal` to `runShellCommand` when present. Other
tools (read_file, write_file, list_directory, apply_patch) use `fs` promises
which do not support `AbortSignal` in the Node versions targeted; they are
allowed to complete naturally. Their durations are bounded by file size and are
not a practical hang risk.

### Tool context wiring in `execute()`

```ts
const toolCtx: ToolContext = {
  cwd,
  runCommandTimeoutSec,
  env: paperclipEnv,
  signal: controller?.signal,    // new
};
```

---

## Interaction with `runCommandTimeoutSec`

Both timeouts are independent and can fire:

| Scenario | Outcome |
|---|---|
| `run_command` finishes within its per-tool timeout, total run within `timeoutSec` | Normal completion |
| `run_command` exceeds its per-tool timeout | Per-tool timeout kills subprocess; tool returns `[timed out]` result; run continues |
| Wall-clock fires while `run_command` is executing | SIGTERM sent to subprocess via abort listener; `execute()` returns `timedOut: true` once the abort propagates |
| Wall-clock fires between tool calls (awaiting OpenAI response) | OpenAI SDK throws AbortError immediately; `execute()` returns `timedOut: true` |

The effective run duration is therefore bounded by `timeoutSec` plus up to one
`run_command` subprocess exit delay (SIGTERM → SIGKILL grace, typically ≤ 1s).

---

## Implementation location

Changes across two files only:

**`src/server/execute.ts`**
- `isAbortError()` helper
- `AbortController` creation and scheduling
- `signal` passed to `chat.completions.create()`
- `signal` in `ToolContext` construction
- Catch block detecting abort → `timedOut` result
- `timeoutSec` documented in `agentConfigurationDoc`

**`src/server/tools.ts`**
- `signal?: AbortSignal` added to `ToolContext`
- `signal` parameter added to `runShellCommand()`
- Abort listener registered and cleaned up in `runShellCommand()`
- `signal` forwarded from `dispatchToolCall` → `runShellCommand`

---

## Tests

In `src/server/execute.test.ts`:

1. **No `timeoutSec` config** — verify no `AbortController` created; run
   completes normally.
2. **`timeoutSec` fires between iterations** — mock OpenAI client that resolves
   normally on first call, then hangs; advance fake timers; verify `execute()`
   returns `{ timedOut: true, errorCode: "timeout" }`.
3. **`timeoutSec` fires during OpenAI call** — mock client that never resolves;
   advance fake timer; verify `AbortError` caught and mapped to `timedOut`.
4. **Partial usage on timeout** — verify `usage.inputTokens` reflects tokens
   consumed before abort.
5. **Timeout does not fire** — run completes before `timeoutSec`; verify timer
   cleared and result is normal.

In `src/server/tools.test.ts`:

6. **`runShellCommand` with signal already aborted** — verify SIGTERM sent
   before command runs.
7. **`runShellCommand` signal fires mid-execution** — mock slow command; fire
   signal; verify SIGTERM sent to subprocess.
8. **`runShellCommand` without signal** — existing behaviour unchanged.

---

## Done when

1. `timeoutSec` config field documented in `agentConfigurationDoc`.
2. `execute()` returns `{ timedOut: true, errorCode: "timeout" }` when wall
   clock expires.
3. In-flight OpenAI HTTP request is aborted via `AbortController` signal.
4. In-flight `run_command` subprocess receives SIGTERM when signal fires.
5. Runs without `timeoutSec` behave identically to today.
6. All tests pass.
