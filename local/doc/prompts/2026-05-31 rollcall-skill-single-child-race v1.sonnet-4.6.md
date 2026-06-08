# Rollcall Skill: Fix Single-Child Wake-Up Race Condition

## Context

The `agent-rollcall` skill lets an agent probe its direct reports by creating child issues and then setting its own issue to `blocked`, waiting for those probes to complete. When a blocker resolves (child issue transitions to `done`), the Paperclip platform fires an `issue_blockers_resolved` wake-up to the parent issue.

This wake-up mechanism has a race condition that routinely affects agents with exactly one direct report.

The race:

1. Agent runs, creates one child probe issue.
2. The child is a fast agent. It picks up the probe, marks it `done` in under ~15 seconds.
3. The child's `done` transition fires the `issue_blockers_resolved` wake. At this moment the parent issue is still `in_progress` (not yet `blocked`), so the wake lands nowhere.
4. The parent run finishes, sets its own issue to `blocked`.
5. No further wake ever arrives. The parent sits `blocked` forever with `unresolvedBlockerCount: 0`.

The platform does have a `blocked_by_nothing` liveness recovery that will eventually surface the issue, but it is a slow recovery path and not a reliable substitute for the first-class wake.

Agents with more direct reports are typically unaffected: with multiple children in flight it is likely that at least one child is still running when the parent sets `blocked`, so the last child's `done` transition fires the wake at the correct moment.

Observed instances: LINAA-874 (Natasha, one direct report: Loki), LINAA-860, LINAA-856. Stark (LINAA-875, seven direct reports) completed cleanly.

The fix must live entirely within the rollcall skill. Modifying Paperclip core server code is out of scope.

## Goal

The rollcall skill must complete successfully regardless of whether a direct report finishes its probe before or after the parent sets its own issue to `blocked`.

## Requirements

1. After creating all child probe issues, the skill must check the current status of each probe before setting its own issue to `blocked`.
2. If all probes are already `done` at that moment, the skill must not set `blocked` at all. It must proceed directly to result aggregation and mark its own issue `done`.
3. If at least one probe is still outstanding, the skill may set `blocked` as before and rely on the platform wake-up.
4. The fix must not introduce polling loops that busy-wait for children to complete.
5. The fix must not require any changes to Paperclip core server or platform code.

## Approach

After the skill dispatches all child probe issues (via `mcp__paperclip__create_issue` or equivalent), and before calling `mcp__paperclip__update_issue` to set `blocked`, fetch the current status of each created probe. If every probe status is `done`, skip the `blocked` transition and jump straight to the aggregation step.

The aggregation step collects each child's result (comments, final status, any reported blockers) and posts a summary comment, then marks the parent issue `done`.

The existing code path for the normal (slow child) case remains unchanged.

## Out of Scope

- Changes to `server/src/routes/issues.ts` or any other Paperclip core file.
- Adding a `becameBlocked` transition handler in the platform.
- Changes to any skill other than `agent-rollcall`.
- Handling the case where a child probe fails or is cancelled (that is a separate concern).

## Acceptance criteria

- An agent with exactly one direct report that completes its probe in under 15 seconds reaches `done` on its own rollcall issue without human intervention.
- An agent with multiple direct reports continues to work as before.
- No new polling loops are introduced.
- The skill script passes any existing linting or test checks in the repo.

## Decisions

- State B queries probes in order after creation. For each probe that is already `done`, it immediately fetches its comments and cost stats and collects the final table rows. The loop stops at the first probe that is not yet `done` — there is no value in querying further probes since the parent is about to set itself `blocked` (declaring all remaining probes as its blockers) and suspend. Any rows collected before the break are still cached.
- The parent sets *itself* to `blocked` with `blockedByIssueIds` pointing to all probe issues. The children do not block each other; the parent declares itself blocked by them.
- State D is the single aggregation path. It reads the cache comment on entry, skips re-querying any covered probe, and runs `update_row_stats` only on fresh rows (probes that completed after suspend). Cached rows already carry final costs.
- If all probes are done at State B time, the cache covers all of them and State B falls through directly to State D without setting `blocked`. A diagnostic comment is posted noting the direct aggregation path.
- When all probes are already `done` and the `blocked` transition is skipped, the skill posts a comment on its own issue noting that it proceeded directly to aggregation. This aids trace diagnostics.

## References

- Skill location: `local/skills/agent-rollcall/`
- Observed race: LINAA-874 (Natasha), LINAA-860, LINAA-856
- Clean completion example: LINAA-875 (Stark, 7 children)
- Platform wake source: `server/src/routes/issues.ts`, `becameDone` block (~L4805), calls `listWakeableBlockedDependents()`
- Liveness recovery (slow path): `server/src/services/recovery/issue-graph-liveness.ts`, reason `blocked_by_nothing`

## Implementation

State B now queries each probe after creation and, for any already done, fetches its comments and cost stats and collects the table rows via a shared `collect_probe_rows` helper. These rows are posted as a `<!-- rollcall-row-cache probes:ID,... -->` comment on the parent issue. If all probes were done, State B falls through directly to State D (no suspend). If some are still running, it sets `blocked` and exits as before.

State D is the single aggregation path for both cases. It reads the cache comment from own issue comments, parses the covered probe identifiers, and skips fetching comments and costs for those probes. Only probes not covered by the cache (arrived done after suspend) are fetched normally. `update_row_stats` runs only on fresh rows; cached rows already carry current costs. The final table combines cached rows and updated fresh rows.

The `collect_probe_rows` helper encapsulates the per-probe row collection logic: it reads the probe's results comment if present, refreshes cost for the probe's own row from the pre-fetched stats, calls `update_row_stats` for any sub-probe rows, and falls back to a metadata row if no results comment exists.

Files changed: `local/skills/agent-rollcall/scripts/agent-rollcall.sh`, `local/skills/agent-rollcall/SKILL.md`.
