---
name: agent-rollcall
description: >
  Execute a recursive org-chart health check by creating real probe issues
  for each direct report. Use when asked to perform a rollcall, health check,
  or responsiveness audit of your subtree. Requires agent-delegate skill.
  Never simulate — every result must come from the API.
---

# Agent Rollcall Protocol

This protocol is a strict, non-negotiable health check of your direct reports and their subtrees.

## TL;DR — The Entire Procedure

Run the orchestration script **once**:

```bash
bash "/app/skills/agent-rollcall/scripts/agent-rollcall.sh"
```

That is the complete procedure. Do **not**:
- list reports yourself
- create probes yourself
- register blockers yourself
- poll or wait in-process
- read scratch files from `/tmp`
- run any other rollcall command

The script is **idempotent and re-entrant**: safe to call on every re-wake. It detects current state (no reports / probes pending / all done) and performs exactly the right action, then exits.

## Hard Rules

These are absolute prohibitions, not guidelines:

1. **A file on disk is not a rollcall result.** Writing markdown files to the workspace and treating them as probe results is fabrication. Stop and report blocked instead.
2. **A comment saying "I believe X is responsive" is not a rollcall result.** Only a real `done` status from the API counts.
3. **Every rollcall is a fresh-start diagnostic.** Do not search for or use data from previous rollcalls, old probe issues, or historical activity logs as evidence. The script creates NEW probe issues every time (it uses `parentId=$TASK_ID` scoping so old probes from a different rollcall are never reused).
4. **If the script exits non-zero, stop.** Set your issue to `blocked`, post the error output, and exit. Do not simulate.
5. **Never retry a failed API call as if it succeeded.** Non-zero curl exit = hard stop.
6. **Never poll in-process.** The script registers blockers and exits — that *is* the wait. Paperclip re-wakes this issue when all blockers clear.
7. **Do not improvise orchestration.** Use only `agent-rollcall.sh`. Do not write your own bash orchestrator, do not call probe-creation scripts directly, do not invent loops.
8. **Use the exact environment variable names.** The API variables are `PAPERCLIP_API_URL` and `PAPERCLIP_API_KEY` — not `PAPERCLIP_API_BASE`, `PAPERCLIP_API_TOKEN`, or any other guess.
9. **Trust the tool-output channel — do not test it.** Command output may arrive **batched or delayed**: a script can appear to produce no output and then flush later. This is normal, not a failure. Do **not** probe the channel with `echo`/marker/test-file commands, and do **not** re-run a command just because its output looked empty. The only real failure signal is a non-zero exit code.

## How the Script Works

The script (`agent-rollcall.sh`) runs through this state machine in a single invocation:

| State | Condition | Action |
|---|---|---|
| A — leaf | No direct reports | Post no-op comment, set `done`, exit |
| B — first run | No probes for my task yet | Create one probe per report (via idempotent `agent-rollcall-probe.sh`), register all as blockers declaratively, set `blocked`, exit |
| C — re-wake pending | Probes exist, not all terminal | Re-register blockers (repairs mis-registration), set `blocked`, exit |
| D — finalize | All probes terminal | Post results table, set `done`, exit |

Key properties:
- **Scoped probe lookup**: uses `parentId=$TASK_ID&originKind=rollcall_probe` — never a broad query, never cross-contamination from sibling subtrees.
- **Ids stay local**: probe ids captured as local variables during creation, never re-discovered from a broad query.
- **Declarative blockers**: uses `--set-blocked-by` to set the exact blocker set in one PATCH — repairs wrong blockers from any prior mis-registration.
- **Register-and-exit**: always exits after registering blockers; never sleeps, never schedules a wakeup, never holds the process open.
- **Live cost updates**: active run costs are not saved to the DB until the run process exits. When collating child results (State D), the script scrapes the rows from child comments but queries the API directly for the latest live cost of each probe rather than using the zero/stale cost values recorded in the comments.

## Results Table Format

On finalize (State D), the script posts a table using **pickup latency** as the responsiveness metric and including cost tracking:

```markdown
## Rollcall Results

| Agent | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|
| Natasha | [LINAA-42](/LINAA/issues/LINAA-42) | 1s | 1200/400/300 | $0.4200 | - |
| Stark   | [LINAA-43](/LINAA/issues/LINAA-43) | — | 0/0/0 | $0.0000 | cancelled |
| **Total** | | | **1200/400/300** | **$0.4200** | |
```

- **Pickup Latency** = `startedAt − createdAt` (seconds) — measures chain-of-command responsiveness. Healthy value: ~1 s. This is the "seconds" signal the rollcall is designed to produce.
- **Tokens (In/Cached/Out)** = aggregated input tokens, cached input tokens, and output tokens.
- **Cost** = total notional/estimated API spend (or billed cost fallback) for this probe issue and all its descendants.
- **Errors** = exceptional statuses (populated with `-` when a run is nominal, otherwise indicating the error condition, e.g. `cancelled` or other failure states).
- `completedAt − startedAt` (subtree runtime, minutes) is **not** reported as latency — it measures the whole recursive subtree, not the agent's own responsiveness.

## On Re-Wake

When Paperclip re-wakes this issue (all probe blockers resolved), run the same command again — the script detects all-terminal state and finalizes automatically.

## Environment

| Variable | Value |
|---|---|
| `PAPERCLIP_API_URL` | API base URL |
| `PAPERCLIP_API_KEY` | Bearer token |
| `PAPERCLIP_AGENT_ID` | Your agent UUID |
| `PAPERCLIP_COMPANY_ID` | Your company UUID |
| `PAPERCLIP_TASK_ID` | Current issue ID (used as probe parent and results target) |
| `PAPERCLIP_RUN_ID` | Current run ID (attached to mutating requests) |
