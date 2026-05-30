#!/usr/bin/env bash
# agent-update-issue.sh
# Update a Paperclip issue's status and/or blocker relationships.
# Exits 0 on success, 1 on error.
#
# Usage: agent-update-issue.sh <issue-id-or-identifier> [options]
#
# Options:
#   --status          <string>   New status: todo, in_progress, blocked, done, cancelled
#   --add-blocked-by  <uuids>    Comma-separated issue UUIDs to add as blockers

set -euo pipefail

API_URL="${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is not set}"
API_KEY="${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is not set}"
RUN_ID="${PAPERCLIP_RUN_ID:-}"

ISSUE_ID="${1:?Usage: agent-update-issue.sh <issue-id> [--status <s>] [--add-blocked-by <ids>]}"
shift

STATUS=""
ADD_BLOCKED_BY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)         STATUS="$2";         shift 2 ;;
    --add-blocked-by) ADD_BLOCKED_BY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$STATUS" && -z "$ADD_BLOCKED_BY" ]]; then
  echo "ERROR: at least one of --status or --add-blocked-by is required" >&2
  exit 1
fi

# Build JSON payload
payload=$(jq -n \
  --arg status "$STATUS" \
  --arg blocked_by "$ADD_BLOCKED_BY" \
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
