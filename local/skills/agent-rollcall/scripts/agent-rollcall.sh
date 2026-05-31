#!/usr/bin/env bash
# agent-rollcall.sh
# Re-entrant, idempotent rollcall orchestrator.
#
# Invoke once per run — it reads the current world-state and performs exactly
# the right action:
#
#   State A — no direct reports   → set self done, exit
#   State B — probes not yet made → create probes, register as blockers, set
#                                    self blocked, exit
#   State C — probes exist, not   → ensure blockers set, set self blocked, exit
#             all terminal          (re-entrancy safety)
#   State D — all probes terminal → post results table, set self done, exit
#
# All authoritative state changes are server-side API calls inside this script.
# Correctness does NOT depend on the agent reading stdout — robust to batched
# or delayed tool-output channels.
#
# Usage: agent-rollcall.sh   (no arguments; reads env)
#
# Required env:
#   PAPERCLIP_AGENT_ID    Your agent UUID
#   PAPERCLIP_TASK_ID     Current issue ID (probe parent + results target)
#   PAPERCLIP_API_URL     API base URL
#   PAPERCLIP_API_KEY     Bearer token
#   PAPERCLIP_COMPANY_ID  Company UUID
#
# Optional env:
#   PAPERCLIP_RUN_ID      Run ID, attached to mutating requests when set
#   SKILL_SOURCE          Absolute path to agent-rollcall skill dir (auto-set
#                         by adapter); script resolves it from its own location
#                         if absent.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve paths & validate required environment
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SKILL_SOURCE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DELEGATE_DIR="$(cd "$SKILL_DIR/../agent-delegate/scripts" && pwd)"

API_URL="${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is not set}"
API_KEY="${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is not set}"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:?PAPERCLIP_COMPANY_ID is not set}"
AGENT_ID="${PAPERCLIP_AGENT_ID:?PAPERCLIP_AGENT_ID is not set}"
TASK_ID="${PAPERCLIP_TASK_ID:?PAPERCLIP_TASK_ID is not set}"
RUN_ID="${PAPERCLIP_RUN_ID:-}"

echo "[rollcall] agent=$AGENT_ID task=$TASK_ID" >&2

# ---------------------------------------------------------------------------
# Helper: curl with auth (and optional run-id on mutations)
# ---------------------------------------------------------------------------
api_get() {
  # api_get <path>
  curl -fs \
    -H "Authorization: Bearer $API_KEY" \
    "${API_URL}${1}"
}

api_patch() {
  # api_patch <path> <json-payload>
  local headers=(-H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
  [[ -n "$RUN_ID" ]] && headers+=(-H "X-Paperclip-Run-Id: $RUN_ID")
  curl -fs -X PATCH \
    "${headers[@]}" \
    -d "$2" \
    "${API_URL}${1}"
}

# ---------------------------------------------------------------------------
# Helper: set my own issue status (+ optional blockedByIssueIds)
# ---------------------------------------------------------------------------
set_self_status() {
  # set_self_status <status> [blocker-ids-json-array]
  local status="$1"
  local blockers="${2:-}"
  local payload
  if [[ -n "$blockers" ]]; then
    payload=$(jq -n --arg s "$status" --argjson b "$blockers" \
      '{status: $s, blockedByIssueIds: $b}')
  else
    payload=$(jq -n --arg s "$status" '{status: $s}')
  fi
  echo "[rollcall] PATCH issue $TASK_ID → status=$status" >&2
  api_patch "/api/issues/$TASK_ID" "$payload" >/dev/null \
    || { echo "ERROR: Failed to PATCH /api/issues/$TASK_ID" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Helper: compute pickup latency string from ISO timestamps
# ---------------------------------------------------------------------------
compute_pickup_latency() {
  # compute_pickup_latency <createdAt> <startedAt>
  # Prints e.g. "36s" or "—" if either timestamp is missing/unparseable.
  local created="$1" started="$2"
  if [[ -z "$created" || -z "$started" ]]; then
    echo "—"; return
  fi
  local ce se
  ce=$(date -d "$created" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${created%%.*}" +%s 2>/dev/null || echo "")
  se=$(date -d "$started" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${started%%.*}" +%s 2>/dev/null || echo "")
  if [[ -n "$ce" && -n "$se" ]]; then
    echo "$(( se - ce ))s"
  else
    echo "—"
  fi
}

# ---------------------------------------------------------------------------
# Helper: build a markdown issue link from an identifier (e.g. LINAA-42)
# ---------------------------------------------------------------------------
make_issue_link() {
  local identifier="$1"
  local prefix
  prefix=$(printf '%s' "$identifier" | sed 's/-[0-9]*$//')
  if [[ -n "$prefix" && "$prefix" != "?" ]]; then
    echo "[${identifier}](/${prefix}/issues/${identifier})"
  else
    echo "$identifier"
  fi
}

# ---------------------------------------------------------------------------
# Helper: fetch issue cost-summary and format as "In/Cached/Out|Cost"
# ---------------------------------------------------------------------------
fetch_issue_stats() {
  # fetch_issue_stats <issue-id-or-identifier>
  local issue_ref="$1"
  local resp cost_cents notional_usd in_tok cached_tok out_tok
  resp=$(api_get "/api/issues/${issue_ref}/cost-summary" 2>/dev/null || echo "{}")
  
  notional_usd=$(printf '%s' "$resp" | jq -r '.notionalCostUsd // empty' 2>/dev/null || echo "")
  cost_cents=$(printf '%s' "$resp" | jq -r '.costCents // empty' 2>/dev/null || echo "")
  in_tok=$(printf '%s' "$resp" | jq -r '.inputTokens // 0' 2>/dev/null || echo "0")
  cached_tok=$(printf '%s' "$resp" | jq -r '.cachedInputTokens // 0' 2>/dev/null || echo "0")
  out_tok=$(printf '%s' "$resp" | jq -r '.outputTokens // 0' 2>/dev/null || echo "0")

  local formatted_cost="—"
  if [[ -n "$notional_usd" && "$notional_usd" != "null" ]]; then
    formatted_cost=$(printf '$%.4f' "$notional_usd")
  elif [[ -n "$cost_cents" && "$cost_cents" != "null" ]]; then
    # Fallback to billed cost in cents
    local dollars cents_part
    dollars=$(( cost_cents / 100 ))
    cents_part=$(( cost_cents % 100 ))
    formatted_cost=$(printf '$%d.%02d' "$dollars" "$cents_part")
  else
    formatted_cost="$0.0000"
  fi

  local formatted_tokens="${in_tok}/${cached_tok}/${out_tok}"

  # Print tokens and cost separated by a pipe
  echo "${formatted_tokens}|${formatted_cost}"
}

# ---------------------------------------------------------------------------
# Helper: sum a list of In/Cached/Out token strings, return total In/Cached/Out
# ---------------------------------------------------------------------------
sum_token_rows() {
  # sum_token_rows <newline-delimited table rows>
  # Extracts the 5th | column from each row and sums the parts.
  local rows="$1"
  printf '%s' "$rows" | awk -F'|' '
    BEGIN {
      in_sum = 0
      cached_sum = 0
      out_sum = 0
    }
    {
      if (NF >= 7) {
        val = $5
        gsub(/[[:space:]]/, "", val)
        if (val ~ /^[0-9]+\/[0-9]+\/[0-9]+$/) {
          split(val, parts, "/")
          in_sum += parts[1]
          cached_sum += parts[2]
          out_sum += parts[3]
        }
      }
    }
    END {
      printf "%d/%d/%d", in_sum, cached_sum, out_sum
    }
  '
}

# ---------------------------------------------------------------------------
# Helper: sum a list of $X.XXXX cost strings, return total $X.XXXX
# ---------------------------------------------------------------------------
sum_cost_rows() {
  # sum_cost_rows <newline-delimited table rows>
  # Extracts the 6th | column from each row, strips $, sums as float.
  local rows="$1"
  printf '%s' "$rows" | awk -F'|' '
    {
      if (NF >= 7) {
        val = $6
        gsub(/[ $]/, "", val)
        if (val ~ /^[0-9.]+$/) {
          sum += val
        }
      }
    }
    END {
      printf "$%.4f", sum
    }
  '
}

# ---------------------------------------------------------------------------
# Helper: update a table row's tokens and cost by querying live stats of its probe
# ---------------------------------------------------------------------------
update_row_stats() {
  # update_row_stats <table_row>
  local row="$1"
  local probe_field
  probe_field=$(printf '%s' "$row" | cut -d'|' -f3)

  local identifier=""
  if [[ "$probe_field" =~ ([A-Z]+-[0-9]+) ]]; then
    identifier="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$identifier" ]]; then
    local stats tokens live_cost
    stats=$(fetch_issue_stats "$identifier")
    tokens=$(printf '%s' "$stats" | cut -d'|' -f1)
    live_cost=$(printf '%s' "$stats" | cut -d'|' -f2)

    local f2 f3 f4 f7
    f2=$(printf '%s' "$row" | cut -d'|' -f2)
    f3=$(printf '%s' "$row" | cut -d'|' -f3)
    f4=$(printf '%s' "$row" | cut -d'|' -f4)
    # Field 5 is old tokens, Field 6 is old cost, Field 7 is errors
    f7=$(printf '%s' "$row" | cut -d'|' -f7)

    echo "|${f2}|${f3}|${f4}| ${tokens} | ${live_cost} |${f7}|"
  else
    echo "$row"
  fi
}

# ---------------------------------------------------------------------------
# 1. List direct reports (scoped: reportsTo == me)
# ---------------------------------------------------------------------------
echo "[rollcall] fetching direct reports..." >&2
reports=$(bash "$DELEGATE_DIR/agent-list-reports.sh" "$AGENT_ID") \
  || { echo "ERROR: agent-list-reports.sh failed" >&2; exit 1; }

report_count=$(printf '%s' "$reports" | jq 'length')
echo "[rollcall] direct reports: $report_count" >&2

# ---------------------------------------------------------------------------
# 2. No reports → leaf node: post own 1-row results table, set done
# ---------------------------------------------------------------------------
if [[ "$report_count" -eq 0 ]]; then
  echo "[rollcall] no direct reports — posting leaf latency row" >&2

  # Fetch own issue to compute pickup latency (createdAt → startedAt)
  own_issue=$(api_get "/api/issues/$TASK_ID") \
    || { echo "ERROR: Failed to fetch own issue $TASK_ID" >&2; exit 1; }
  own_identifier=$(printf '%s' "$own_issue" | jq -r '.identifier // "?"')
  own_title=$(printf '%s' "$own_issue" | jq -r '.title // "?"')
  own_agent=$(printf '%s' "$own_title" | sed 's/^Rollcall Probe - //')
  own_created=$(printf '%s' "$own_issue" | jq -r '.createdAt // empty')
  own_started=$(printf '%s' "$own_issue" | jq -r '.startedAt // empty')
  own_pickup=$(compute_pickup_latency "$own_created" "$own_started")
  own_link=$(make_issue_link "$own_identifier")
  own_stats=$(fetch_issue_stats "$TASK_ID")
  own_tokens=$(printf '%s' "$own_stats" | cut -d'|' -f1)
  own_cost=$(printf '%s' "$own_stats" | cut -d'|' -f2)

  comment=$(cat <<MD
## Rollcall Results

| Agent | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|
| ${own_agent} | ${own_link} | ${own_pickup} | ${own_tokens} | ${own_cost} | - |
MD
)

  bash "$DELEGATE_DIR/agent-comment.sh" "$TASK_ID" "$comment" >/dev/null \
    || { echo "ERROR: Failed to post leaf results comment" >&2; exit 1; }
  set_self_status "done"
  echo "[rollcall] done (leaf node, pickup=${own_pickup}, cost=${own_cost})" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Look up MY existing probes (scoped: parentId=$TASK_ID, originKind=rollcall_probe)
#    Never a broad/recent query; never /tmp scratch.
# ---------------------------------------------------------------------------
echo "[rollcall] fetching existing probes for task $TASK_ID..." >&2
existing_probes=$(api_get \
  "/api/companies/$COMPANY_ID/issues?parentId=$TASK_ID&originKind=rollcall_probe") \
  || { echo "ERROR: Failed to fetch existing probes" >&2; exit 1; }

probe_count=$(printf '%s' "$existing_probes" | jq 'length')
echo "[rollcall] existing probes: $probe_count" >&2

# ---------------------------------------------------------------------------
# 4. Branch on state
# ---------------------------------------------------------------------------

# Utility: are all probes terminal?
all_terminal() {
  # Returns exit-0 if every probe has status in {done,cancelled}
  printf '%s' "$existing_probes" | jq -e \
    '[.[] | select(.status != "done" and .status != "cancelled")] | length == 0' \
    >/dev/null 2>&1
}

# ---- State B: no probes yet — create them ---------------------------------
if [[ "$probe_count" -eq 0 ]]; then
  echo "[rollcall] State B: creating probes..." >&2

  probe_ids=()

  while IFS= read -r report; do
    r_id=$(printf '%s' "$report" | jq -r '.id')
    r_name=$(printf '%s' "$report" | jq -r '.name')
    echo "[rollcall]   creating probe for $r_name ($r_id)..." >&2

    # agent-rollcall-probe.sh is idempotent; safe to call even on re-entry
    probe_output=$(bash "$SKILL_DIR/scripts/agent-rollcall-probe.sh" \
      --agent-id "$r_id" \
      --agent-name "$r_name" \
      --parent "$TASK_ID") \
      || { echo "ERROR: probe creation failed for $r_name" >&2; exit 1; }

    # First non-empty line of stdout is the identifier (e.g. LINAA-42);
    # second line is the full JSON blob.
    probe_json=$(printf '%s' "$probe_output" | tail -n +2 | head -n 1)
    probe_id=$(printf '%s' "$probe_json" | jq -r '.id // empty')

    if [[ -z "$probe_id" ]]; then
      echo "ERROR: no probe id returned for $r_name" >&2
      echo "$probe_output" >&2
      exit 1
    fi

    echo "[rollcall]   probe for $r_name → id=$probe_id" >&2
    probe_ids+=("$probe_id")
  done < <(printf '%s' "$reports" | jq -c '.[]')

  # Build JSON array of probe ids for declarative blocker set
  blocker_array=$(printf '%s\n' "${probe_ids[@]}" | jq -R . | jq -sc .)
  echo "[rollcall] registering blockers: $blocker_array" >&2
  set_self_status "blocked" "$blocker_array"
  echo "[rollcall] probes created and registered; exiting (Paperclip will re-wake)" >&2
  exit 0
fi

# ---- State C: probes exist but not all terminal ---------------------------
if ! all_terminal; then
  echo "[rollcall] State C: probes pending — ensuring blockers set, exiting" >&2

  # Declaratively re-register the exact current probe set as blockers.
  # This repairs any mis-registration from a previous run (the 793 failure mode).
  blocker_array=$(printf '%s' "$existing_probes" | jq '[.[].id]')
  set_self_status "blocked" "$blocker_array"
  echo "[rollcall] blockers confirmed; exiting (Paperclip will re-wake)" >&2
  exit 0
fi

# ---- State D: all probes terminal — collate rows and finalize -------------
# Strategy: each probe's agent posted a "## Rollcall Results" comment on its
# own issue containing its complete subtree table (recursively built bottom-up).
# We extract those rows and concatenate them. No tree-walking needed here.
echo "[rollcall] State D: all probes terminal — collating results" >&2

table_rows=""

# Self-row: include only when this issue is itself a rollcall_probe
# (intermediate node). The root trigger (routine_execution) is the orchestrator
# and is not itself a measured report.
own_issue=$(api_get "/api/issues/$TASK_ID") \
  || { echo "ERROR: Failed to fetch own issue" >&2; exit 1; }
own_origin_kind=$(printf '%s' "$own_issue" | jq -r '.originKind // empty')

if [[ "$own_origin_kind" == "rollcall_probe" ]]; then
  own_identifier=$(printf '%s' "$own_issue" | jq -r '.identifier // "?"')
  own_title=$(printf '%s' "$own_issue" | jq -r '.title // "?"')
  own_agent=$(printf '%s' "$own_title" | sed 's/^Rollcall Probe - //')
  own_created=$(printf '%s' "$own_issue" | jq -r '.createdAt // empty')
  own_started=$(printf '%s' "$own_issue" | jq -r '.startedAt // empty')
  own_pickup=$(compute_pickup_latency "$own_created" "$own_started")
  own_link=$(make_issue_link "$own_identifier")
  own_stats=$(fetch_issue_stats "$TASK_ID")
  own_tokens=$(printf '%s' "$own_stats" | cut -d'|' -f1)
  own_cost=$(printf '%s' "$own_stats" | cut -d'|' -f2)
  table_rows="| ${own_agent} | ${own_link} | ${own_pickup} | ${own_tokens} | ${own_cost} | - |"$'\n'
  echo "[rollcall] self-row: $own_agent pickup=${own_pickup} tokens=${own_tokens} cost=${own_cost}" >&2
fi

# Collate rows from each probe's results comment
while IFS= read -r probe; do
  p_id=$(printf '%s' "$probe" | jq -r '.id // empty')
  p_identifier=$(printf '%s' "$probe" | jq -r '.identifier // "?"')
  p_status=$(printf '%s' "$probe" | jq -r '.status // "unknown"')
  p_agent=$(printf '%s' "$probe" | jq -r '.title // "?"' | sed 's/^Rollcall Probe - //')
  p_link=$(make_issue_link "$p_identifier")

  if [[ -z "$p_id" ]]; then continue; fi

  # Fetch the probe issue's comments; find the most recent Rollcall Results block
  probe_comments=$(api_get "/api/issues/$p_id/comments" 2>/dev/null || echo "[]")
  results_body=$(printf '%s' "$probe_comments" | jq -r \
    '[.[] | select(.body | contains("## Rollcall Results"))] | last | .body // empty' \
    2>/dev/null || echo "")

  if [[ -n "$results_body" ]]; then
    # Extract data rows: | lines that are not the header (| Agent |) or separator (|---|)
    # Also skip the Total footer row (| **Total** |) so we can recompute it
    data_rows=$(printf '%s' "$results_body" \
      | grep '^|' \
      | grep -v '^|[-|[:space:]]*$' \
      | grep -vi '^| *agent *|' \
      | grep -vi '^| *\*\*total\*\* *|')
    if [[ -n "$data_rows" ]]; then
      row_count=$(printf '%s' "$data_rows" | wc -l | tr -d ' ')
      echo "[rollcall]   $p_agent: collated $row_count row(s) from results comment" >&2
      table_rows="${table_rows}${data_rows}"$'\n'
      continue
    fi
  fi

  # Fallback: no results comment found (agent cancelled, timed out, or old-style
  # comment). Generate a single row from probe metadata + cost API.
  echo "[rollcall]   $p_agent: no results comment — generating fallback row (status=$p_status)" >&2
  if [[ "$p_status" == "done" ]]; then
    error_status="-"
  elif [[ "$p_status" == "cancelled" ]]; then
    error_status="cancelled"
  else
    error_status="$p_status"
  fi
  p_created=$(printf '%s' "$probe" | jq -r '.createdAt // empty')
  p_started=$(printf '%s' "$probe" | jq -r '.startedAt // empty')
  p_pickup=$(compute_pickup_latency "$p_created" "$p_started")
  p_stats=$(fetch_issue_stats "$p_id")
  p_tokens=$(printf '%s' "$p_stats" | cut -d'|' -f1)
  p_cost=$(printf '%s' "$p_stats" | cut -d'|' -f2)
  table_rows="${table_rows}| ${p_agent} | ${p_link} | ${p_pickup} | ${p_tokens} | ${p_cost} | ${error_status} |"$'\n'

done < <(printf '%s' "$existing_probes" | jq -c '.[]')

# Update the costs of all collected rows using live data from the API
updated_rows=""
while IFS= read -r row; do
  if [[ -n "$row" ]]; then
    updated_row=$(update_row_stats "$row")
    updated_rows="${updated_rows}${updated_row}"$'\n'
  fi
done <<< "$table_rows"
table_rows="$updated_rows"

# Compute grand total cost and tokens from all collected rows
total_tokens=$(sum_token_rows "$table_rows")
total_cost=$(sum_cost_rows "$table_rows")
echo "[rollcall] grand total tokens: $total_tokens cost: $total_cost" >&2

comment=$(cat <<MD
## Rollcall Results

| Agent | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|
${table_rows}| **Total** | | | **${total_tokens}** | **${total_cost}** | |
MD
)

echo "[rollcall] posting results comment..." >&2
bash "$DELEGATE_DIR/agent-comment.sh" "$TASK_ID" "$comment" >/dev/null \
  || { echo "ERROR: Failed to post results comment" >&2; exit 1; }

set_self_status "done"
echo "[rollcall] done" >&2
exit 0
