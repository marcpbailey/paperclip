---
name: agent-delegate
description: >
  Delegate work to other agents by creating real Paperclip issues via the API.
  Use when you need to assign tasks to direct reports, poll their progress,
  or post structured results back to a parent issue. Covers: list direct reports,
  create issue, poll to completion, add comment, update status.
---

# SKILL

Use this skill whenever you need to create issues for your direct reports, wait for
results, or post outcomes back to a parent issue. All operations MUST use the
Paperclip API — never simulate delegation by writing files to disk.

## Environment (auto-injected every run)

| Variable | Value |
|---|---|
| `PAPERCLIP_API_URL` | API base URL |
| `PAPERCLIP_API_KEY` | Bearer token for all requests |
| `PAPERCLIP_AGENT_ID` | Your agent UUID |
| `PAPERCLIP_COMPANY_ID` | Your company UUID |
| `PAPERCLIP_RUN_ID` | Current run ID — include on all mutating requests |

All requests: `Authorization: Bearer $PAPERCLIP_API_KEY`
All mutating requests also require: `X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID`

## Hard Rules

1. **If a curl call returns an error or non-2xx status — stop immediately.** Post
   the raw error as a comment on the current issue and set status to `blocked`.
   Never proceed as if the operation succeeded.

2. **Verify creation.** After `POST`ing an issue, check the response contains an
   `identifier` (e.g. `LINAA-42`). If it does not, the issue was not created —
   stop and report.

3. **Never write markdown files as fake issues.** A file named `probe_thor.md`
   is not a Paperclip issue. Thor will never see it.

4. **Never guess your org chart from filesystem state.** Always query the API.
   Stale files from previous runs will mislead you.

5. **Trust the tool-output channel — do not test it.** Command output may arrive
   batched or delayed; a command can look like it produced nothing and then flush
   later. That is normal, not a failure. Do not probe the channel with `echo`/
   marker/test-file commands, and do not re-run a command because its output looked
   empty. The only real failure signal is a non-zero exit code.

## API Patterns

All patterns use `run_command` with curl. Use `-f` (fail on HTTP error) and `-s`
(silent) so errors propagate clearly.

### 1 — Who am I?

```bash
run_command: curl -fs \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  "$PAPERCLIP_API_URL/api/agents/me"
```

Returns your `id`, `name`, `companyId`, `reportsTo`, and `capabilities`.

### 2 — List my direct reports

Do NOT append a query parameter filter (like `?reportsTo=...`) directly to the API URL, as the server's agents list endpoint does not support query parameter filtering and will return a 400 Bad Request error. Instead, use the helper script:

```bash
run_command: bash /app/skills/agent-delegate/scripts/agent-list-reports.sh
```

Or make a raw request and filter locally using `jq`:

```bash
run_command: curl -fs \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  "$PAPERCLIP_API_URL/api/companies/$PAPERCLIP_COMPANY_ID/agents" | jq --arg id "$PAPERCLIP_AGENT_ID" '[.[] | select(.reportsTo == $id)]'
```

Returns an array of direct reports. If empty, you have no direct reports — respond with a
no-op comment on your issue and stop. **Do not invent direct reports.**

### 3 — Create a probe issue

```bash
run_command: curl -fs -X POST \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
        --arg title    "Rollcall Probe - Thor" \
        --arg assignee "<thor-agent-id>" \
        --arg status   "todo" \
        --arg parentId "<current-issue-id>" \
        --arg desc     "<full issue description text>" \
        '{title:$title, assigneeAgentId:$assignee, status:$status,
          parentId:$parentId, description:$desc}')" \
  "$PAPERCLIP_API_URL/api/companies/$PAPERCLIP_COMPANY_ID/issues"
```

Check the response: if `.identifier` is null or missing, the create failed. Stop.

Use helper script for convenience (see Scripts section below).

### 4 — Wait for a child issue to finish (do NOT poll in-process)

> **Each run is a one-shot process — there is no background thread.** Sitting in a
> blocking poll loop (`sleep`, `agent-poll-issue.sh`, `ScheduleWakeup`) holds the
> process open, burns turns and wall-clock, and accomplishes nothing the platform
> doesn't already do for free. **Never poll in-process to wait for a child.**

The correct fan-in is dependency-driven, not poll-driven:

1. Create the child issue(s) (Pattern 3).
2. Register them as blockers on your own issue and set your status to `blocked`:
   ```bash
   run_command: bash /app/skills/agent-delegate/scripts/agent-update-issue.sh \
     "$PAPERCLIP_TASK_ID" --add-blocked-by "<childId1>,<childId2>,..." --status blocked
   ```
3. **Exit.** Paperclip re-wakes your issue automatically once every blocker reaches
   a terminal status. On re-wake, read each child's final status via Pattern 1 and
   continue.

`agent-poll-issue.sh` still exists for rare interactive/debug use, but it must
**never** be used as a rollcall or delegation fan-in mechanism. If you find
yourself wanting to "wait", register blockers and exit instead.

### 5 — Add a comment to an issue

```bash
run_command: bash /app/skills/agent-delegate/scripts/agent-comment.sh \
  "<issue-id-or-identifier>" "$(cat <<'MD'
## My comment

- Bullet one
- Bullet two
MD
)"
```

### 6 — Update issue status

```bash
run_command: curl -fs -X PATCH \
  -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  -H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID" \
  -H "Content-Type: application/json" \
  -d '{"status":"done"}' \
  "$PAPERCLIP_API_URL/api/issues/<issue-id>"
```

Status values: `todo` `in_progress` `in_review` `done` `blocked` `cancelled`

## Scripts

The following scripts are available in `skills/agent-delegate/scripts/`.
All scripts inherit `PAPERCLIP_API_URL`, `PAPERCLIP_API_KEY`, `PAPERCLIP_COMPANY_ID`,
and `PAPERCLIP_RUN_ID` from the environment.

| Script | Purpose |
|---|---|
| `agent-list-reports.sh` | Print direct reports as JSON array |
| `agent-create-issue.sh` | Create an issue, print identifier on success |
| `agent-poll-issue.sh` | Block until issue reaches done/cancelled or timeout — **interactive/debug only; never use for rollcall or delegation fan-in (see Pattern 4)** |
| `agent-comment.sh` | Post a markdown comment to an issue |

## Rollcall Pattern

**The `agent-rollcall` skill's `SKILL.md` is the single source of truth for rollcall.**
Follow it exactly; do not invent a parallel procedure here. In particular:

- Create **exactly one** probe per direct report with `agent-rollcall-probe.sh`
  (which is idempotent — it reuses an existing probe for the same report instead
  of creating a duplicate). Call it **once** per report; never re-run the create
  step and never write your own orchestration script.
- **Do not poll in-process.** Register the probes as blockers, set your issue to
  `blocked`, and exit (see Pattern 4). Paperclip re-wakes you when they resolve.
- On re-wake, read each probe's final status via Pattern 1, post the results
  table to the parent issue, and set your own issue to `done`.

Never report an agent as "responsive" unless you received a real `done` status
from the API on their probe issue.
