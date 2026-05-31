# Plan: Absorb agent-delegate into agent-rollcall

## Background

`agent-delegate` was originally a text-only SKILL.md for general agent delegation. It
has since grown scripts that are **exclusively consumed by `agent-rollcall`** — no other
code references them. The `paperclip` skill now covers the general-purpose delegation
use case for non-rollcall agents. The separate skill therefore has no remaining purpose
and creates unnecessary complexity: two volume mounts, a fragile sibling-directory
dependency, and two skills to maintain.

## Goal

Merge `local/skills/agent-delegate/` into `local/skills/agent-rollcall/` so rollcall is
fully self-contained. Delete `agent-delegate` entirely.

## Files involved

**Source (agent-delegate — to be deleted after merge):**
- `local/skills/agent-delegate/SKILL.md`
- `local/skills/agent-delegate/scripts/agent-list-reports.sh`
- `local/skills/agent-delegate/scripts/agent-create-issue.sh`
- `local/skills/agent-delegate/scripts/agent-update-issue.sh`
- `local/skills/agent-delegate/scripts/agent-comment.sh`
- `local/skills/agent-delegate/scripts/agent-poll-issue.sh` ← delete, do not migrate (deprecated)

**Destination (agent-rollcall — to be updated):**
- `local/skills/agent-rollcall/scripts/agent-rollcall.sh`
- `local/skills/agent-rollcall/scripts/agent-rollcall-probe.sh`
- `local/skills/agent-rollcall/SKILL.md`

**Compose (volume mount to remove):**
- `local/compose/paperclip-boot-linkcast.yaml`

## Steps

### 1. Move scripts

Copy these four scripts into `local/skills/agent-rollcall/scripts/`:
- `agent-list-reports.sh`
- `agent-create-issue.sh`
- `agent-update-issue.sh`
- `agent-comment.sh`

Do NOT migrate `agent-poll-issue.sh` — it is explicitly deprecated by the rollcall
protocol and must not be used.

### 2. Update agent-rollcall.sh

In `local/skills/agent-rollcall/scripts/agent-rollcall.sh`, change the path resolution
block (currently lines 39-41):

```bash
# BEFORE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SKILL_SOURCE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DELEGATE_DIR="$(cd "$SKILL_DIR/../agent-delegate/scripts" && pwd)"
```

```bash
# AFTER
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Then replace every `"$DELEGATE_DIR/..."` reference in the script with `"$SCRIPT_DIR/..."`.
There are three call sites:
- `bash "$DELEGATE_DIR/agent-list-reports.sh"` (line ~250)
- `bash "$DELEGATE_DIR/agent-comment.sh"` (line ~285)
- `bash "$DELEGATE_DIR/agent-comment.sh"` (line ~476)

Also remove the comment in the file header that references `SKILL_SOURCE` and
`DELEGATE_DIR` as optional env vars — they are no longer needed.

### 3. Update agent-rollcall-probe.sh

In `local/skills/agent-rollcall/scripts/agent-rollcall-probe.sh`, change the delegate
path resolution (currently lines 26-28):

```bash
# BEFORE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve agent-delegate scripts relative to this skill's location
DELEGATE_DIR="$(cd "$SCRIPT_DIR/../../agent-delegate/scripts" && pwd)"
```

```bash
# AFTER
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Then replace `"$DELEGATE_DIR/agent-create-issue.sh"` with `"$SCRIPT_DIR/agent-create-issue.sh"`
(the final `exec` call at the bottom of the script).

### 4. Update agent-rollcall SKILL.md

Remove the line "Requires agent-delegate skill." from the frontmatter description.

### 5. Remove the agent-delegate volume mount

In `local/compose/paperclip-boot-linkcast.yaml`, remove:
```yaml
      - ../local/skills/agent-delegate:/app/skills/agent-delegate:ro
```

### 6. Delete agent-delegate

Delete the entire `local/skills/agent-delegate/` directory.

### 7. Verify

Run a rollcall (trigger via Paperclip UI or create a rollcall issue). Confirm:
- State B executes (probes created, blockers registered)
- State D executes on re-wake (results table posted, issue set done)
- No references to `/app/skills/agent-delegate/` appear in run transcripts

## What does NOT change

- The scripts themselves (agent-list-reports.sh etc.) — their content is correct as-is,
  only their location changes
- The rollcall protocol and state machine
- The SKILL.md invocation: `bash "/app/skills/agent-rollcall/scripts/agent-rollcall.sh"`
- Any agent configs or skill assignments (agent-delegate was never explicitly assigned
  to agents by config — it was auto-registered as a bundled skill)
