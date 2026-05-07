# Feature: Native Paperclip API Tools for `openrouter-local`

## Objective

Add typed, first-class tool definitions for common Paperclip control-plane
operations alongside the existing filesystem/shell tools, creating a hybrid
tool model that is both structured and flexible.

## Motivation

Agents currently reach the Paperclip API via `run_command` + curl. This works
for capable models but has three concrete weaknesses:

- **Reliability**: the model must infer the correct API shape from injected
  documentation; weaker and free-tier models are error-prone here.
- **Observability**: curl calls appear opaque in transcripts; typed tool calls
  are immediately legible.
- **Governance**: approval gating for `hire_agent` cannot be enforced against
  arbitrary shell commands.

Priority: **low now** — the adapter is working. Rises when free-tier or
smaller models are in active use (likely once dynamic model listing ships), or
when `hire_agent` governance becomes a requirement.

---

## Hybrid tool model

The adapter exposes two complementary toolsets to the model simultaneously:

| Toolset | Tools | Purpose |
|---|---|---|
| Filesystem / shell | `read_file`, `write_file`, `list_directory`, `run_command`, `apply_patch` | Workspace manipulation — unchanged |
| Paperclip API | `get_issue`, `update_issue_status`, `add_comment`, `list_comments`, `create_sub_issue`, `list_issues`, `list_agents`, `hire_agent`, `request_approval` | Control-plane operations — new |

Both sets are passed to the model. The system prompt should note that
Paperclip API tools are preferred over curl for control-plane operations;
in practice models strongly prefer typed schemas when available.

The existing `disabledTools` agent config applies across both sets — operators
can suppress individual tools from either group by name.

---

## New file: `src/server/paperclip-api.ts`

A thin HTTP client adapted from
[talhamahmood666/paperclip-adapter-openrouter](https://github.com/talhamahmood666/paperclip-adapter-openrouter).
Nearly identical to the source; adapted to remove the external dependency and
align imports with the monorepo.

### Base URL resolution (priority order)

1. `PAPERCLIP_API_URL` env var (already injected by `buildPaperclipEnv`)
2. `http://localhost:3100` (default dev port)

Auth is per-instance: `authToken` from `AdapterExecutionContext`.

### Exposed methods

```ts
class PaperclipApi {
  // Issues
  getIssue(issueId: string): Promise<Record<string, unknown>>
  updateIssue(issueId: string, patch: Record<string, unknown>): Promise<Record<string, unknown>>
  checkoutIssue(issueId: string, agentId: string, expectedStatuses?: string[]): Promise<Record<string, unknown>>
  listCompanyIssues(companyId: string, query?: Record<string, string>): Promise<Record<string, unknown>>
  createIssue(companyId: string, issue: Record<string, unknown>): Promise<Record<string, unknown>>

  // Comments
  listIssueComments(issueId: string): Promise<Record<string, unknown>>
  addIssueComment(issueId: string, body: { body: string }): Promise<Record<string, unknown>>

  // Agents
  listCompanyAgents(companyId: string): Promise<Record<string, unknown>[]>
  hireAgent(companyId: string, hire: Record<string, unknown>): Promise<Record<string, unknown>>

  // Approvals
  createApproval(companyId: string, approval: Record<string, unknown>): Promise<Record<string, unknown>>
}
```

`PaperclipApiError` carries `status`, `body`, and `endpoint` for structured
error returns to the model.

---

## Issue checkout

Paperclip enforces a `sameRunLock` check: write operations (`add_comment`,
`update_issue_status`) on an issue reject with `409` if the current run does
not hold the issue lock. Checkout must happen before any write tool can
succeed.

**Implementation**: call `checkoutIssue` once at the start of `execute()`,
before the tool loop begins, whenever a `currentIssueId` is available in the
wake context. This is not a model-facing tool — it is an adapter-level
lifecycle step.

```ts
// In execute(), after building the PaperclipApi instance:
const currentIssueId = resolveCurrentIssueId(context);
if (currentIssueId && apiClient) {
  try {
    await apiClient.checkoutIssue(currentIssueId, agent.id);
  } catch (err) {
    if (err instanceof PaperclipApiError && err.status === 409) {
      // Another run holds the lock — abort cleanly.
      await onLog("stdout", `[paperclip] Issue ${currentIssueId} is locked by another run. Aborting.\n`);
      return { exitCode: 1, signal: null, timedOut: false, errorMessage: "Issue run ownership conflict", errorCode: "issue_locked" };
    }
    // Non-409 failures are logged but do not abort — write tools will
    // surface their own 409s if the lock is actually required.
    await onLog("stderr", `[paperclip] Issue checkout warning: ${err instanceof Error ? err.message : String(err)}\n`);
  }
}
```

`resolveCurrentIssueId` reads from `context.paperclipWake?.issue?.id` or
`context.taskId`, whichever is present.

This also addresses **row 6 (issue checkout / pre-lock detection)** from the
adapter comparison, at no additional cost.

---

## ToolContext extension

`ToolContext` in `src/server/tools.ts` gains optional Paperclip API fields:

```ts
export interface ToolContext {
  cwd: string;
  runCommandTimeoutSec: number;
  env?: Record<string, string>;
  // New — populated only when Paperclip API tools are enabled:
  paperclipApi?: PaperclipApi;
  agentId?: string;
  companyId?: string;
  currentIssueId?: string | null;
  autoApprove?: boolean;
}
```

Fields are optional so that the existing filesystem tools compile and test
without any Paperclip API dependency.

---

## Tool definitions

New file: `src/server/paperclip-tools.ts`

Exports `buildPaperclipTools(ctx: ToolContext): ToolHandler[]`. Returns an
empty array if `ctx.paperclipApi` is absent (safe default when auth token is
missing).

The identity fields (`agentId`, `companyId`, `currentIssueId`) are read from
`ctx` at dispatch time rather than accepted as model arguments, preventing the
model from spoofing identity across tool calls.

### Tool schemas

#### `get_issue`
```ts
parameters: {
  issue_id: { type: "string", description: "Issue ID to fetch. Defaults to the current issue if omitted." }  // optional
}
```
Returns: full issue object as JSON (title, description, status, comments,
attachments).

#### `update_issue_status`
```ts
parameters: {
  status: { type: "string", enum: ["open", "in_progress", "blocked", "done", "cancelled"] },
  issue_id?: string  // optional, defaults to current issue
}
```

#### `add_comment`
```ts
parameters: {
  body: { type: "string", description: "Markdown comment body." },
  issue_id?: string
}
```

#### `list_comments`
```ts
parameters: {
  issue_id?: string
}
```

#### `create_sub_issue`
```ts
parameters: {
  title: { type: "string" },
  description?: { type: "string" },
  assignee_id?: { type: "string", description: "Agent ID to assign. Use list_agents to discover IDs." },
  priority?: { type: "string", enum: ["low", "medium", "high", "urgent"] }
}
```
Parent is always the current issue. `companyId` is captured from context.

#### `list_issues`
```ts
parameters: {
  status?: { type: "string" },
  assignee_id?: { type: "string" },
  limit?: { type: "number", description: "Max results (default 20)." }
}
```

#### `list_agents`
```ts
parameters: {}  // no arguments
```
Returns trimmed agent objects: `id`, `name`, `role`, `adapterType`, `model`,
`status`. Used to discover assignee IDs before delegation.

#### `hire_agent`
```ts
parameters: {
  name: { type: "string" },
  role: { type: "string" },
  adapter_type: { type: "string" },
  model?: { type: "string" }
}
```
See approval gating below.

#### `request_approval`
```ts
parameters: {
  reason: { type: "string", description: "Why approval is needed." },
  action: { type: "string", description: "What will happen if approved." }
}
```

---

## Approval gating for `hire_agent`

When `ctx.autoApprove` is `false` (the default), the `hire_agent` tool does
not call `hireAgent()` directly. Instead it calls `createApproval()` and
returns a message indicating that the hire is pending human review.

When `ctx.autoApprove` is `true`, `hireAgent()` is called immediately.

`autoApprove` is exposed as an agent config field:

```ts
// In agentConfigurationDoc:
// - autoApprove (boolean, optional, default false): skip approval workflow for
//   hire_agent and other governed operations. Only set true in trusted,
//   fully-automated company configurations.
```

---

## Wiring into `execute.ts`

```ts
import { buildPaperclipTools } from "./paperclip-tools.js";
import { PaperclipApi } from "./paperclip-api.js";

// Inside execute():
const autoApprove = config.autoApprove === true;
const apiClient = ctx.authToken
  ? new PaperclipApi({ authToken: ctx.authToken })
  : null;

const currentIssueId = resolveCurrentIssueId(context); // reads wake context

// ... checkout logic (see above) ...

const toolCtx: ToolContext = {
  cwd,
  runCommandTimeoutSec,
  env: paperclipEnv,
  paperclipApi: apiClient ?? undefined,
  agentId: agent.id,
  companyId: agent.companyId,
  currentIssueId,
  autoApprove,
};

const paperclipTools = buildPaperclipTools(toolCtx);
const allTools = [...(options.tools ?? DEFAULT_TOOLS), ...paperclipTools].filter(
  (t) => !disabledTools.has(t.name),
);
```

If `authToken` is absent, `buildPaperclipTools` returns `[]` and the adapter
runs filesystem-tools-only, as today. No config change required for existing
agents.

---

## Implementation files

```
packages/adapters/openrouter-local/src/server/
  paperclip-api.ts       — PaperclipApi client (new)
  paperclip-tools.ts     — buildPaperclipTools() and tool definitions (new)
  execute.ts             — checkout + tool wiring (modified)
  tools.ts               — ToolContext extension (modified)
```

---

## Tests

In `src/server/paperclip-tools.test.ts`:

1. **`buildPaperclipTools` returns empty array** when `ctx.paperclipApi` is
   absent — filesystem-only path stays clean.
2. **`get_issue`** — mock api, verify correct endpoint called, issue_id
   defaults to `ctx.currentIssueId` when not provided.
3. **`add_comment`** — verify `addIssueComment` called with correct body.
4. **`create_sub_issue`** — verify `companyId` sourced from context, not args.
5. **`hire_agent` with `autoApprove: false`** — verify `createApproval` called,
   `hireAgent` not called.
6. **`hire_agent` with `autoApprove: true`** — verify `hireAgent` called
   directly.
7. **API error handling** — mock a `PaperclipApiError`; verify tool returns
   `isError: true` with status and message in content.

In `src/server/execute.test.ts` (extend existing):

8. **Checkout success** — mock `checkoutIssue` resolves; run proceeds normally.
9. **Checkout 409** — mock `checkoutIssue` rejects with status 409; execute
   returns `errorCode: "issue_locked"` without entering the tool loop.
10. **No authToken** — verify no checkout attempted, Paperclip tools absent
    from tool list.

---

## Done when

1. `PaperclipApi` client in place and unit tested.
2. All 9 Paperclip tools defined, dispatching correctly against mock API.
3. `hire_agent` approval gating verified by test.
4. Checkout lifecycle runs at start of `execute()` when issue context is
   present; 409 produces clean abort.
5. Existing filesystem tool tests unaffected.
6. `autoApprove` documented in `agentConfigurationDoc`.
7. No behaviour change for agents without an `authToken`.
