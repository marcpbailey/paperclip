# 2026-05-31 became-inactive-wake-fix v1.sonnet-4.6

## Context

Paperclip agents execute as heartbeat runs. Each run acquires an environment
lease for the duration of the agent's LLM turn and releases it when the turn
ends. The issue lifecycle has a known recovery path for a "blocked by nothing"
state: when all of an issue's blockers resolve, the platform fires an
`issue_blockers_resolved` wake that starts a new run for the parent.

However, there is a timing gap. The following sequence causes a stuck issue:

1. Parent run (e.g. Natasha, LINAA-884) creates a child probe issue and sets
   itself to `blocked`, listing the probe as its blocker. The script exits
   immediately after. The LLM run, however, continues processing for some
   seconds (sometimes up to ~90s) before releasing its lease.
2. The child probe (e.g. Loki, LINAA-885) completes while the parent's LLM
   run is still active.
3. `issue_blockers_resolved` fires. The parent is already in `blocked` state,
   so the wake is correctly targeted. But the parent's run still holds the
   lease, preventing a new run from starting.
4. The wake is not re-delivered after the lease is released. The parent sits
   `blocked` with `unresolvedBlockerCount: 0` indefinitely.
5. The `blocked_by_nothing` liveness recovery (a timer-driven sweep in
   `server/src/services/recovery/issue-graph-liveness.ts`) eventually detects
   the state, but this is a slow path and not reliable for production use.

Observed instances: LINAA-884 (this exact sequence, confirmed via activity
log). Prior instances: LINAA-874, LINAA-860, LINAA-856 (the original
single-child race, partially mitigated in the rollcall skill).

The `becameDone` block in `server/src/routes/issues.ts` (~L4805) calls
`listWakeableBlockedDependents()` to wake parent issues when a child
completes. There is no symmetric check on the run side: when a run ends, the
platform does not re-check whether the issue it was running is itself stuck.

## Goal

When a heartbeat run ends (lease released), if the associated issue is in
`blocked` state with `unresolvedBlockerCount == 0`, immediately trigger a
re-wake for that issue. No timers. No polling. Triggered solely by the
lease-release event.

## Requirements

1. On lease release for any issue, the platform must check: is this issue
   `blocked` AND `unresolvedBlockerCount == 0`?
2. If yes, immediately enqueue or trigger the equivalent of an
   `issue_blockers_resolved` wake for that issue.
3. The check must be synchronous with (or immediately consequent to) the
   lease-release event, not scheduled.
4. The fix must not create duplicate runs if a valid wake is already pending.
5. The fix must not interfere with the existing `blocked_by_nothing` liveness
   recovery (that path can remain as a backstop).
6. No changes to skill code or agent prompts.

## Approach

Add a `becameInactive` check at the point where a heartbeat run releases its
lease. After the lease is marked released, fetch the issue's current state. If
`status == "blocked"` and `unresolvedBlockerCount == 0`, call the same wake
logic that `listWakeableBlockedDependents()` ultimately invokes for the issue
itself (not its dependents).

The existing `blocked_by_nothing` recovery in
`server/src/services/recovery/issue-graph-liveness.ts` already knows how to
handle this state; the goal here is to trigger it on the event rather than on
a schedule. Whether the implementation reuses that recovery logic, calls a
shared helper, or duplicates a small amount of targeted logic is an
implementation decision left to the author (prefer reuse if the surface is
clean).

The lease-release handler is the natural hook. Locate where
`environment.lease_released` activity is written in `server/src/routes/` or
the relevant service, and add the check there.

## Out of Scope

- Changes to skill scripts or agent prompts.
- Changes to the `blocked_by_nothing` liveness recovery schedule (leave it as
  a backstop).
- Addressing any other run lifecycle states (e.g. `cancelled`, `failed`). This
  fix targets `blocked` + `unresolvedBlockerCount == 0` only.
- Investigating why the LLM run takes up to 90s after the script exits (that
  is a separate concern).

## Acceptance Criteria

- A parent issue that is `blocked` with a single child blocker, where the
  child completes while the parent's run is still active, receives a new run
  within a few seconds of the parent's run releasing its lease.
- No duplicate runs are started if a valid wake was already queued before
  lease release.
- `pcc make fulltest` passes on the branch.

## References

- Branch to use: `fork/feat-becameInactive-event`, created from
  `origin/master` per the Integration Manager workflow in `local/_AGENTS.md`
- `becameDone` wake source: `server/src/routes/issues.ts`, `becameDone` block
  (~L4805), calls `listWakeableBlockedDependents()`
- Slow-path recovery: `server/src/services/recovery/issue-graph-liveness.ts`,
  reason `blocked_by_nothing`
- Observed instance: LINAA-884 (parent), LINAA-885 (child, Loki), run
  `6cbcc347` (Natasha's run that held the lease 78s after child completed)
- Activity log evidence: lease released at 10:18:54, child done at 10:17:36,
  no second run ever started for LINAA-884
- Contribution flow: `local/_AGENTS.md` (Integration Manager Workflow section)
