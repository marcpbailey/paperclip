# Agent Rollcall — Theory of Operation

This document explains how the rollcall skill and its scripts work. It is
reference material for humans and future maintainers — **not loaded by agents**.
The agent-facing instructions are in `SKILL.md`.

## Overview

A rollcall is a recursive org-chart health check. The orchestrating agent
creates one "probe" issue per direct report, waits for them to complete
(each probe recursively does the same for its own reports), then collates
results into a table showing pickup latency, token usage, and cost.

The entire state machine lives in `scripts/agent-rollcall.sh`. The agent's
only job is to invoke it and trust its output.

## State Machine

`agent-rollcall.sh` is re-entrant and idempotent — safe to call on every
wake. It reads live API state and performs exactly the right action:

| State | Condition | Action |
|---|---|---|
| **A** — leaf | No direct reports | Post own 1-row results table, set `done`, exit |
| **B** — first run | No probes for this task yet | Create one probe per report; collect rows + costs for any already-done probes; post a `<!-- rollcall-row-cache -->` comment; if all probes already done, fall through to D; otherwise register remaining probes as blockers, set `blocked`, exit |
| **C** — re-wake pending | Probes exist, not all terminal | Declaratively re-register the exact probe set as blockers (repairs any prior mis-registration), set `blocked`, exit |
| **D** — finalize | All probes terminal | Read row cache from own comments; use cached rows for covered probes; fetch fresh rows for uncached probes; run `update_row_stats` on fresh rows only; post combined results table, set `done`, exit |

## Key Design Properties

**Scoped probe lookup** — uses `parentId=$TASK_ID&originKind=rollcall_probe`.
Never a broad/recent query; never cross-contamination from sibling subtrees.

**Ids stay local** — probe ids captured as local variables at creation time,
never re-discovered from a broad query.

**Declarative blockers** — `--set-blocked-by` sets the exact blocker set in
one PATCH, repairing mis-registration from any prior run.

**Register-and-exit** — always exits after registering blockers; never sleeps,
never schedules a wakeup, never holds the process open. Paperclip's blocker
resolution re-wakes the issue.

**Row cache** — State B queries each probe immediately after creation. For
any already-done probes, it collects table rows and final costs and posts them
as a `<!-- rollcall-row-cache probes:LINAA-x,LINAA-y -->` comment. State D
reads this cache and skips re-querying covered probes. Cost accuracy is
preserved: cached rows were fetched after `done`, uncached rows get a live
cost refresh via `update_row_stats`.

**Self-row logic** — a probe that is itself an intermediate node
(`originKind=rollcall_probe`) includes its own pickup latency row at the top
of the results. The root trigger issue (`originKind=routine_execution`) does
not include a self-row — it is the orchestrator, not a measured report.

**Tool-output robustness** — all authoritative state changes are server-side
API calls. Correctness does not depend on the agent reading stdout; output may
be batched or delayed without affecting correctness.

## Results Table Format

```markdown
## Rollcall Results

| Agent | Model | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|---|
| Natasha | opus-4.8 | [LINAA-42](/LINAA/issues/LINAA-42) | 1s | 1200/400/300 | $0.4200 | - |
| Stark   | haiku-4.5 | [LINAA-43](/LINAA/issues/LINAA-43) | — | 0/0/0 | $0.0000 | cancelled |
| **Total** | | | | **1200/400/300** | **$0.4200** | |
```

- **Pickup Latency** = `startedAt − createdAt` (seconds). Measures chain-of-command responsiveness. Healthy: ~1s. High values indicate the agent was slow to pick up the probe — could be queue depth, heartbeat disabled, or cold start.
- **Tokens (In/Cached/Out)** = aggregated across the probe issue and all its descendants.
- **Cost** = total notional/estimated API spend for the probe subtree (`/api/issues/{id}/cost-summary`).
- **Errors** = `-` for nominal runs; `cancelled` or other status for exceptions.
- Subtree runtime (`completedAt − startedAt`) is **not** reported — it measures the full recursive depth, not the agent's own responsiveness.

## Script Inventory

| Script | Purpose |
|---|---|
| `agent-rollcall.sh` | Main orchestrator — state machine, row collation, results posting |
| `agent-rollcall-probe.sh` | Creates a single probe issue for one report |
| `agent-list-reports.sh` | Lists agents with `reportsTo == $AGENT_ID` |
| `agent-comment.sh` | Posts a comment to an issue |
| `agent-create-issue.sh` | Creates an issue (used by probe script) |
| `agent-update-issue.sh` | Updates issue status / blockers |

## Diagnosing Rollcall Runs

The primary diagnostic tool is the `/trace-issue-run` skill — invoke it with a rollcall issue identifier (e.g. `/trace-issue-run LINAA-953`) to get a structured diagnosis: issue state, run timeline, transcript highlights, delegation trace, and root cause. It automatically recurses into child probe issues one level deep.

For lower-level inspection, use `local/bin/paperclip-api.sh` for authenticated API calls directly. It handles auth via `op run` without exposing the API key directly. Never use `curl $PAPERCLIP_API_KEY` directly.

```bash
# Fetch issue state
local/bin/paperclip-api.sh GET /api/issues/LINAA-xxx | jq '{status,assigneeAgentId,startedAt,completedAt}'

# Fetch runs for an issue
local/bin/paperclip-api.sh GET /api/issues/LINAA-xxx/runs | jq '[.[] | {runId,status,startedAt,finishedAt}]'

# Fetch comments (e.g. check results table format)
local/bin/paperclip-api.sh GET /api/issues/LINAA-xxx/comments | jq '[.[] | {body: .body[:500]}]'

# Fetch and parse a run transcript (filter for rollcall log lines)
local/bin/paperclip-api.sh GET /api/heartbeat-runs/<runId>/log | python3 -c "
import json, sys
data = json.load(sys.stdin)
for line in data.get('content', '').split('\n'):
    try:
        e = json.loads(line)
        chunk = e.get('chunk', '')
        if '[rollcall]' in chunk or 'ERROR' in chunk or 'exit code' in chunk:
            print(chunk.strip())
    except: pass
"
```

For MCP-covered operations (issues, agents, comments, goals), prefer `mcp__paperclip__*` tools instead. The API helper is for operations not yet exposed via MCP — run transcripts, cost summaries, and run logs.

## Environment Variables

| Variable | Purpose |
|---|---|
| `PAPERCLIP_AGENT_ID` | Running agent's UUID |
| `PAPERCLIP_TASK_ID` | Current issue ID — used as probe parent and results target |
| `PAPERCLIP_API_URL` | API base URL |
| `PAPERCLIP_API_KEY` | Bearer token |
| `PAPERCLIP_COMPANY_ID` | Company UUID |
| `PAPERCLIP_RUN_ID` | Run ID — attached to mutating requests when set (optional) |

## Platform Fix: becameInactive Wake on Lease Release

A related race exists at the platform level: if a child probe completes while the parent run still holds its environment lease, `issue_blockers_resolved` fires but is lost — the lease blocks a new run from starting, and the wake is never re-delivered after the lease drops.

Fixed in `server/src/services/heartbeat.ts` (commit `ce263cbb5`, cherry-picked onto `linkcast/main`): after the lease is released in the `executeRun` finally block, if the run's issue is `blocked` with `unresolvedBlockerCount == 0`, the fix immediately calls `enqueueWakeup` with `reason: issue_blockers_resolved`. `enqueueWakeup` handles deduplication, so no duplicate runs are created. The existing `blocked_by_nothing` liveness recovery is left as a slow-path backstop.

This fix is a hard dependency for correct rollcall behaviour — without it, fast-completing probes could leave the parent stalled indefinitely.

## Race Condition Fix: Probes Completing Before Parent Blocks

A subtle race exists in State B: after probe issues are created, any fast-starting
agent may reach `done` before the parent has called `set_self_status "blocked"`.
If that happens and the parent then sets itself to `blocked` on those already-terminal
probes, Paperclip has no remaining unresolved blockers to watch — so the re-wake
never fires and the rollcall stalls indefinitely.

The fix is the **optimistic collection loop** in State B. Immediately after creating
each probe, the script queries its status. If it is already `done`, the script
collects its table rows and final costs into a `<!-- rollcall-row-cache -->` comment
and marks it as covered. Collection stops at the first non-done probe (to avoid
burning API calls on ones that haven't started yet).

If **all** probes are done by the time the loop finishes, the script posts a notice
comment and falls through directly to State D — it never sets `blocked` at all,
so there is no stale-blocker problem. If some probes are still pending, the script
registers only the pending ones as blockers; the already-done probes' rows are in
the cache and State D reads them without re-querying.

This means State D is always correct regardless of timing: cached rows came from
the already-done probes (final costs, no re-query needed); fresh rows come from
probes that completed after the suspend (costs refreshed by `update_row_stats`).

## Agent Workspace Symlinks and Company-Wide Context

### The Problem

Paperclip resolves an agent's working directory at run time using this priority
order: project workspace → previous task session cwd → agent home fallback. When
an issue has no project (as is the case for routine-triggered pings, rollcalls,
and most operational tasks), the harness falls through to the **agent home
fallback** at:

```
/paperclip/instances/default/workspaces/{agentId}
```

This UUID-named directory is not under the company tree, so Claude Code's
`AGENTS.md` auto-loading — which walks up from the cwd — never reaches
`/paperclip/AGENTS.md` or the agent's own `AGENTS.md` in
`/paperclip/companies/linkcast/agents/{name}/`. Agents were therefore running
with no company context for any projectless issue.

There is no per-agent workspace field on the agent schema (upstream issue #1425,
open). `instructionsRootPath` in `adapterConfig` is not used as cwd (upstream
bug #2443, open).

### The Fix: UUID Directory Symlinks

`local/bin/link-agent-workspaces.sh` replaces each agent's UUID fallback directory
with a symlink to their company workspace:

```
/paperclip/instances/default/workspaces/{agentId}
  → /paperclip/companies/linkcast/agents/{name}
```

The harness still resolves and records the UUID path as the workspace, but the OS
resolves it through the symlink, so the agent's actual cwd is the company agents
directory. Claude Code's `AGENTS.md` walk then finds both the agent's own
`AGENTS.md` and traverses up to `/paperclip/AGENTS.md`.

The script is idempotent (re-running prints `OK` for already-correct symlinks) and
backs up any real directory content to `{uuid}.bak` before replacing it.

### The Fix: Company-Wide Include

`local/bin/prepend-agents-include.sh` prepends the following line to every agent's
`AGENTS.md`:

```
@/paperclip/AGENTS.md
```

This makes the include explicit and load-order-guaranteed regardless of how Claude
Code resolves the directory walk. Even if the cwd resolution ever changes, the
include is hardwired into the agent's own instructions file.

`/paperclip/AGENTS.md` contains company-wide rules, architectural context, and
cross-cutting constraints that all agents must observe. The `@` include syntax
causes Claude Code to inline the referenced file as part of the system prompt
before the agent's own instructions.

Both scripts must be re-run after a container rebuild, as the symlinks and
`AGENTS.md` edits live inside the container volume, not in the source tree.

## Why the Hard Rules Exist

The hard rules in `SKILL.md` encode specific failure modes that have been
observed in practice:

- **Rules 1 & 2** (no file/comment as result) — agents were writing markdown
  files to the workspace or posting "I believe X is responsive" comments and
  treating them as probe results. Only a real `done` API status counts.
- **Rule 3** (fresh-start) — agents were reusing stale probe issues or
  historical activity data from previous rollcalls, producing phantom results.
- **Rule 4** (non-zero = stop) — agents were retrying on failure and inventing
  results rather than surfacing the error.
- **Rule 6** (no in-process polling) — agents were sleeping in-process waiting
  for probes to complete instead of registering blockers and exiting.
- **Rule 7** (no improvised orchestration) — agents were writing their own
  bash loops or calling sub-scripts directly instead of using `agent-rollcall.sh`.
- **Rule 9** (trust output channel) — agents were re-running scripts because
  stdout looked empty, causing duplicate probe creation and double-posting.
