---
name: agent-rollcall
description: >
  Execute a recursive org-chart health check by creating real probe issues
  for each direct report. Use when asked to perform a rollcall, health check,
  or responsiveness audit of your subtree. Never simulate — every result must
  come from the API.
---

# Agent Rollcall Protocol

This protocol is a strict, non-negotiable health check of your direct reports and their subtrees.

## The Entire Procedure

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

The script is **idempotent and re-entrant**: safe to call on every re-wake.

## Hard Rules

1. **A file on disk is not a rollcall result.** Writing markdown files to the workspace and treating them as probe results is fabrication. Stop and report blocked instead.
2. **A comment saying "I believe X is responsive" is not a rollcall result.** Only a real `done` status from the API counts.
3. **Every rollcall is a fresh-start diagnostic.** Do not use data from previous rollcalls, old probe issues, or historical activity logs. The script creates NEW probe issues every time.
4. **If the script exits non-zero, stop.** Set your issue to `blocked`, post the error output, and exit. Do not simulate.
5. **Never retry a failed API call as if it succeeded.** Non-zero curl exit = hard stop.
6. **Never poll in-process.** The script registers blockers and exits — that *is* the wait. Paperclip re-wakes this issue when all blockers clear.
7. **Do not improvise orchestration.** Use only `agent-rollcall.sh`. Do not write your own bash orchestrator, do not call probe-creation scripts directly, do not invent loops.
8. **Use the exact environment variable names.** The API variables are `PAPERCLIP_API_URL` and `PAPERCLIP_API_KEY` — not any other guess.
9. **Trust the tool-output channel — do not test it.** Command output may arrive **batched or delayed**: a script can appear to produce no output and then flush later. This is normal. Do **not** probe the channel with test commands, and do **not** re-run a command just because its output looked empty. The only real failure signal is a non-zero exit code.

## On Re-Wake

When Paperclip re-wakes this issue (because probe blockers resolved), run **exactly the same command** again:

```bash
bash "/app/skills/agent-rollcall/scripts/agent-rollcall.sh"
```

The re-wake context will contain `childIssueSummaries` showing sub-probe results. **Do not use these to write your own summary.** Do not post a "Rollcall Complete" comment. Do not compose a results table manually. The script reads the API directly and posts the canonical `## Rollcall Results` table — that is the only acceptable output. Anything else breaks aggregation in parent rollcalls.
