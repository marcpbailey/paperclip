#!/usr/bin/env bash
# agent-update-issue.sh
# Update a Paperclip issue's status and/or blocker relationships.
# Exits 0 on success, 1 on error.
#
# Usage: agent-update-issue.sh <issue-id-or-identifier> [options]
#
# Options:
#   --status          <string>   New status: todo, in_progress, blocked, done, cancelled
#   --add-blocked-by  <uuids>    Comma-separated issue UUIDs to ADD to the current blocker set
#   --set-blocked-by  <uuids>    Comma-separated issue UUIDs to SET as the complete blocker set
#                                (replaces any previously registered blockers)

set -euo pipefail

API_URL="${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is not set}"
API_KEY="${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is not set}"
RUN_ID="${PAPERCLIP_RUN_ID:-}"

ISSUE_ID="${1:?Usage: agent-update-issue.sh <issue-id> [--status <s>] [--add-blocked-by <ids>] [--set-blocked-by <ids>]}"
shift

STATUS=""
ADD_BLOCKED_BY=""
SET_BLOCKED_BY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)         STATUS="$2";         shift 2 ;;
    --add-blocked-by) ADD_BLOCKED_BY="$2"; shift 2 ;;
    --set-blocked-by) SET_BLOCKED_BY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$STATUS" && -z "$ADD_BLOCKED_BY" && -z "$SET_BLOCKED_BY" ]]; then
  echo "ERROR: at least one of --status, --add-blocked-by, or --set-blocked-by is required" >&2
  exit 1
fi

if [[ -n "$ADD_BLOCKED_BY" && -n "$SET_BLOCKED_BY" ]]; then
  echo "ERROR: --add-blocked-by and --set-blocked-by are mutually exclusive" >&2
  exit 1
fi

# Resolve blocker ids: prefer --set-blocked-by (declarative replace) over
# --add-blocked-by (additive).  Both send as blockedByIssueIds; the API treats
# the array as the new complete set.
BLOCKED_BY="${SET_BLOCKED_BY:-$ADD_BLOCKED_BY}"

# Build JSON payload
payload=$(jq -n \
  --arg status "$STATUS" \
  --arg blocked_by "$BLOCKED_BY" \
  '{}
  | if $status != "" then . + {status: $status} else . end
  | if $blocked_by != "" then . + {blockedByIssueIds: ($blocked_by | split(","))} else . end
  ')

headers=(-H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
if [[ -n "$RUN_ID" ]]; then
  headers+=(-H "X-Paperclip-Run-Id: $RUN_ID")
fi

response=$(curl -fs -X PATCH \
  "${headers[@]}" \
  -d "$payload" \
  "$API_URL/api/issues/$ISSUE_ID") \
  || { echo "ERROR: PATCH /api/issues/$ISSUE_ID failed" >&2; echo "$response" >&2; exit 1; }

echo "$response"
