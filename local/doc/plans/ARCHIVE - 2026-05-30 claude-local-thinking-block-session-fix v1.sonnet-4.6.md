# ARCHIVE - 2026-05-30 claude-local-thinking-block-session-fix v1.sonnet-4.6

## Context

The Paperclip platform uses a `claude_local` adapter (`packages/adapters/claude-local/`) to run agents
via the Claude CLI subprocess. Session continuity across heartbeat runs is implemented by passing
`--resume <sessionId>` to the CLI. The adapter stores and restores session IDs between runs via
`runtime.sessionParams.sessionId`.

The adapter already handles two session-failure modes in `execute.ts`:

- **Unknown session** (`isClaudeUnknownSessionError`): matches "no conversation found with session id",
  "unknown session", etc. On match, retries the same invocation immediately with `null` session and
  sets `clearSession: true` so Paperclip discards the stale session ID.
- **Transient upstream** (`isClaudeTransientUpstreamError`): matches rate-limits, 429, 503, overloaded.
  Schedules a backoff retry.

There is a third failure mode that is not handled: the Anthropic API rejects a resumed session with
HTTP 400 when the previous run's assistant turn contained `thinking` or `redacted_thinking` blocks
that have since been modified or incompletely persisted by the Claude CLI's session store. The exact
error message pattern is:

```
thinking or redacted_thinking blocks in the latest assistant message cannot be modified.
These blocks must remain as they were in the original response.
```

Because this error matches neither classifier, the adapter:

1. Returns the failed result without setting `clearSession: true`.
2. Paperclip retains the corrupted session ID.
3. Every subsequent retry immediately hits the same 400, failing within seconds.
4. After three consecutive failures Paperclip auto-cancels the issue via
   `recovery.silent_cancel_declarable_origin`.

This was observed in production on LINAA-729 (Rollcall Probe for Natasha, assigned to agent
`1652248b`). Natasha uses `model: claude-opus-4-8`, which produces thinking blocks by default.
Run 1 crashed mid-turn, saving a corrupt session. Runs 2 and 3 each failed in under 4 seconds with
the same 400. The cancellation left its parent issue (LINAA-728) permanently stuck in `blocked`
because the dependency-wakeup requires all blockers to reach `done`.

The adapter source lives in `packages/adapters/claude-local/src/server/`. The relevant files are:
- `execute.ts`: main execution and session-resume logic
- `parse.ts`: error classification helpers (`isClaudeUnknownSessionError`, `isClaudeTransientUpstreamError`, etc.)

## Goal

When the Claude CLI returns the thinking-block 400 error, the adapter must discard the bad session and
retry with a fresh session in the same run, exactly as it already does for unknown-session errors.

## Requirements

1. Add a new exported function `isClaudeThinkingBlockError` in `parse.ts` that returns `true` when
   the parsed result or error message contains the thinking-block 400 error pattern.
2. In `execute.ts`, add a branch for `isClaudeThinkingBlockError` alongside the existing
   `isClaudeUnknownSessionError` branch: retry with `runAttempt(null)` and pass
   `clearSessionOnMissingSession: true` to `toAdapterResult`.
3. The check must only trigger when a session was being resumed (`sessionId` is non-null at the start
   of the attempt). A fresh-session run that somehow produces this error should not loop.
4. Add unit tests in `parse.test.ts` (or the nearest test file covering `parse.ts`) covering:
   - A result whose `result` text contains the thinking-block message returns `true`.
   - An unrelated error message returns `false`.
5. Add a test in `execute` tests (or a new describe block) verifying that a thinking-block failure
   on a resume attempt triggers a fresh-session retry, analogous to the existing unknown-session test.

## Approach

Pattern mirrors the `isClaudeUnknownSessionError` path exactly. In `execute.ts` the block to add is:

```ts
if (
  sessionId &&
  !initial.proc.timedOut &&
  isClaudeThinkingBlockError(initial.parsed ?? {})
) {
  await onLog("stdout", `[paperclip] Claude session "${sessionId}" contains unresumable thinking blocks; retrying with a fresh session.\n`);
  const retry = await runAttempt(null);
  return toAdapterResult(retry, { fallbackSessionId: null, clearSessionOnMissingSession: true });
}
```

The regex for `isClaudeThinkingBlockError` should match the literal phrase produced by the Anthropic API:

```
thinking.*blocks.*cannot be modified|redacted_thinking.*blocks.*cannot be modified
```

Case-insensitive. Match against `parsed.result`, `parsed.errors`, and the raw error message string
(same haystacks used by `describeClaudeFailure` and `isClaudeUnknownSessionError`).

Consider whether to also set `clearSession: true` on the retry result if the retry itself fails.
The existing unknown-session path uses `clearSessionOnMissingSession: true`, which sets
`clearSession` only when `resolvedSessionId` is falsy on the result. That is sufficient.

## Out of Scope

- Fixing the Claude CLI's thinking-block persistence behaviour (that is an upstream issue).
- Changing the dependency-wakeup logic to treat `cancelled` blockers as resolved (separate issue,
  but noted as a related gap: a cancelled blocker currently leaves the parent permanently blocked).
- Changing Natasha's model to avoid thinking blocks (valid workaround but not the fix).

## Acceptance Criteria

- A new run for an issue whose previous run ended with the thinking-block 400 error completes
  without immediately failing. The adapter logs the "unresumable thinking blocks" message and starts
  a fresh session.
- `isClaudeThinkingBlockError` returns `true` for the exact error string observed in production:
  `API Error: 400 messages.3.content.8: thinking or redacted_thinking blocks in the latest
  assistant message cannot be modified.`
- `isClaudeThinkingBlockError` returns `false` for rate-limit errors and unknown-session errors.
- Unit and integration tests pass (`vitest` in `packages/adapters/claude-local/`).

## Open Questions

- Should `isClaudeThinkingBlockError` also be checked when `sessionId` is null? (Unlikely to occur,
  but worth deciding whether to guard explicitly or silently no-op.)
- Is there a test fixture mechanism for simulating Claude CLI subprocess output in the execute tests,
  or do those tests mock at the process-runner level? Check
  `server/src/__tests__/claude-local-execute.test.ts` before writing new tests.
- The error message format (`messages.3.content.8`) includes positional indices. Confirm the regex
  does not over-anchor on those indices, since they may vary across sessions.

## References

- Adapter source: `packages/adapters/claude-local/src/server/execute.ts` (session-resume logic
  around line 944, `isClaudeUnknownSessionError` branch)
- Parser helpers: `packages/adapters/claude-local/src/server/parse.ts`
- Execute tests: `server/src/__tests__/claude-local-execute.test.ts`
- Parse tests: `packages/adapters/claude-local/src/server/parse.test.ts`
- Production incident: LINAA-729 (Natasha probe), parent LINAA-728, observed 2026-05-30
- Observed error string: `Claude run failed: subtype=success: API Error: 400 messages.3.content.8:
  thinking or redacted_thinking blocks in the latest assistant message cannot be modified. These
  blocks must remain as they were in the original response.`
