#!/usr/bin/env bash
# agent-rollcall-probe.sh
# Create a standardised rollcall probe issue for a single direct report.
# Wraps agent-create-issue.sh with a fixed title and description template so
# probe descriptions are always consistent.
#
# IDEMPOTENT: before creating, this script checks whether a probe already exists
# for the same (parent, assignee) pair — in ANY status, including cancelled. If
# one does, it reuses that probe instead of creating a duplicate. This guarantees
# *exactly one* probe per report per rollcall — even if the step is retried,
# re-woken, or run more than once. Calling it repeatedly for the same report is
# safe. (A cancelled probe is a real terminal rollcall outcome — "unresponsive",
# per the protocol's no-retry rule — so it must suppress creation, not trigger a
# fresh probe; otherwise the report would end up with two tickets.)
#
# Usage:
#   agent-rollcall-probe.sh --agent-id <uuid> --agent-name <name> --parent <issue-id>
#
# Output: prints the probe identifier (e.g. LINAA-42) on the first line of stdout,
#         followed by the full issue JSON (same shape as agent-create-issue.sh).
#         A reused probe is annotated with "[idempotent] reusing ..." on stderr.
# Exits 0 on success, 1 on error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve agent-delegate scripts relative to this skill's location
DELEGATE_DIR="$(cd "$SCRIPT_DIR/../../agent-delegate/scripts" && pwd)"

API_URL="${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is not set}"
API_KEY="${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is not set}"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID is not set}"

AGENT_ID=""
AGENT_NAME=""
PARENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-id)   AGENT_ID="$2";   shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --parent)     PARENT="$2";     shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$AGENT_ID" || -z "$AGENT_NAME" || -z "$PARENT" ]]; then
  echo "ERROR: --agent-id, --agent-name, and --parent are all required" >&2
  exit 1
fi

TITLE="Rollcall Probe - $AGENT_NAME"

# --- Idempotency guard ---------------------------------------------------
# Look for an existing probe this rollcall already created for this report:
# same parent (= this rollcall's task) AND same assignee, in ANY status
# (cancelled included). The (parent, assignee) key is scoped to the current
# rollcall, so probes from previous rollcalls (which have a different parent) are
# correctly ignored. Any existing probe suppresses creation — a cancelled probe
# is itself a terminal "unresponsive" result and must not spawn a replacement.
existing=$(curl -fs \
  -H "Authorization: Bearer $API_KEY" \
  "$API_URL/api/companies/$COMPANY_ID/issues?parentId=$PARENT&assigneeAgentId=$AGENT_ID&status=todo,in_progress,in_review,blocked,done,cancelled" \
  2>/dev/null) || existing=""

if [[ -n "$existing" ]]; then
  # Reuse an existing probe if any exists. Prefer a non-cancelled one (it carries
  # a usable outcome); otherwise fall back to the earliest cancelled one. Either
  # way creation is suppressed, so the report keeps exactly one ticket.
  match=$(printf '%s' "$existing" | jq -c \
    '(([.[] | select(.status != "cancelled")] | sort_by(.issueNumber) | .[0]) // (sort_by(.issueNumber) | .[0])) // empty' \
    2>/dev/null || true)
  if [[ -n "$match" && "$match" != "null" ]]; then
    identifier=$(printf '%s' "$match" | jq -r '.identifier // empty')
    if [[ -n "$identifier" ]]; then
      echo "[idempotent] reusing existing probe $identifier for $AGENT_NAME (parent $PARENT)" >&2
      echo "$identifier"
      echo "$match"
      exit 0
    fi
  fi
fi
# --- end idempotency guard -----------------------------------------------

DESCRIPTION="Perform a recursive rollcall of your **direct reports** using the **\`agent-rollcall\`** skill.

This is a fresh-start diagnostic: **disregard all previous rollcall history, past comments, and old probe results.** Follow the protocol in your skill's \`SKILL.md\` strictly. If you have no direct reports, set this issue to \`done\` immediately to confirm you are operational."

exec "$DELEGATE_DIR/agent-create-issue.sh" \
  --title "$TITLE" \
  --assignee "$AGENT_ID" \
  --parent "$PARENT" \
  --status "todo" \
  --origin-kind "rollcall_probe" \
  --description "$DESCRIPTION"
