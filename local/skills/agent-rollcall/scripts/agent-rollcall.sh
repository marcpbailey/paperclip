#!/usr/bin/env bash
# agent-rollcall.sh
# Re-entrant, idempotent rollcall orchestrator.
#
# Invoke once per run — it reads the current world-state and performs exactly
# the right action:
#
#   State A — no direct reports   → set self done, exit
#   State B — probes not yet made → create probes; query each probe and
#                                    collect rows + costs for any already done;
#                                    post a row-cache comment; if all done,
#                                    fall through to State D without suspending;
#                                    otherwise register blockers, set blocked, exit
#   State C — probes exist, not   → ensure blockers set, set self blocked, exit
#             all terminal          (re-entrancy safety)
#   State D — all probes terminal → read row cache (if any); skip re-querying
#                                    cached probes; fetch fresh rows for the
#                                    remainder; combine and post results, set done
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

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve paths & validate required environment
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  echo "[rollcall] PATCH issue $TASK_ID -> status=$status" >&2
  api_patch "/api/issues/$TASK_ID" "$payload" >/dev/null \
    || { echo "ERROR: Failed to PATCH /api/issues/$TASK_ID" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Helper: compute pickup latency string from ISO timestamps
# ---------------------------------------------------------------------------
compute_pickup_latency() {
  # compute_pickup_latency <createdAt> <startedAt>
  # Prints e.g. "36s" or "-" if either timestamp is missing/unparseable.
  local created="$1" started="$2"
  if [[ -z "$created" || -z "$started" ]]; then
    echo "-"; return
  fi
  local ce se
  ce=$(date -d "$created" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${created%%.*}" +%s 2>/dev/null || echo "")
  se=$(date -d "$started" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${started%%.*}" +%s 2>/dev/null || echo "")
  if [[ -n "$ce" && -n "$se" ]]; then
    echo "$(( se - ce ))s"
  else
    echo "-"
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

  local formatted_cost="--"
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
# Helper: shorten a full model name to a compact display form
# e.g. claude-opus-4-8 → opus-4.8, claude-haiku-4-5-20251001 → haiku-4.5
# ---------------------------------------------------------------------------
shorten_model_name() {
  printf '%s' "$1" \
    | sed 's/^claude-//' \
    | sed 's/-\([0-9]\)/.\1/g' \
    | sed 's/\(\.[0-9]\{1,2\}\)\.[0-9]\{6,\}$/\1/'
}

# ---------------------------------------------------------------------------
# Helper: determine the model this agent is actually running on for this issue.
# Reads assigneeAdapterOverrides from own issue JSON, resolves against own
# agent config. Called by the probe itself — not by the parent.
# ---------------------------------------------------------------------------
fetch_own_model() {
  local own_issue_json="$1"
  local model_profile="" model="" agent_resp=""
  model_profile=$(printf '%s' "$own_issue_json" | jq -r '.assigneeAdapterOverrides.modelProfile // empty' 2>/dev/null || echo "")
  agent_resp=$(api_get "/api/agents/$AGENT_ID" 2>/dev/null || echo "{}")
  if [[ -n "$model_profile" ]]; then
    model=$(printf '%s' "$agent_resp" \
      | jq -r --arg p "$model_profile" \
        '.runtimeConfig.modelProfiles[$p].adapterConfig.model // empty' \
      2>/dev/null || echo "")
  fi
  if [[ -z "$model" ]]; then
    model=$(printf '%s' "$agent_resp" | jq -r '.adapterConfig.model // empty' 2>/dev/null || echo "")
  fi
  shorten_model_name "${model:-unknown}"
}

# ---------------------------------------------------------------------------
# Helper: sum a list of In/Cached/Out token strings, return total In/Cached/Out
# Table columns: | Agent | Model | Probe | Pickup | Tokens | Cost | Errors |
# Tokens are in column 6 (1-indexed, with leading empty col from leading |).
# ---------------------------------------------------------------------------
sum_token_rows() {
  local rows="$1"
  printf '%s' "$rows" | awk -F'|' '
    BEGIN { in_sum = 0; cached_sum = 0; out_sum = 0 }
    {
      if (NF >= 8) {
        val = $6
        gsub(/[[:space:]]/, "", val)
        if (val ~ /^[0-9]+\/[0-9]+\/[0-9]+$/) {
          split(val, parts, "/")
          in_sum += parts[1]; cached_sum += parts[2]; out_sum += parts[3]
        }
      }
    }
    END { printf "%d/%d/%d", in_sum, cached_sum, out_sum }
  '
}

# ---------------------------------------------------------------------------
# Helper: sum a list of $X.XXXX cost strings, return total $X.XXXX
# Cost is in column 7.
# ---------------------------------------------------------------------------
sum_cost_rows() {
  local rows="$1"
  printf '%s' "$rows" | awk -F'|' '
    {
      if (NF >= 8) {
        val = $7
        gsub(/[ $]/, "", val)
        if (val ~ /^[0-9.]+$/) { sum += val }
      }
    }
    END { printf "$%.4f", sum }
  '
}

# ---------------------------------------------------------------------------
# Helper: update a table row's tokens and cost by querying live stats of its probe
# ---------------------------------------------------------------------------
update_row_stats() {
  # update_row_stats <table_row>
  # Columns: | Agent | Model | Probe | Pickup | Tokens | Cost | Errors |
  local row="$1"
  local probe_field
  probe_field=$(printf '%s' "$row" | cut -d'|' -f4)

  local identifier=""
  if [[ "$probe_field" =~ ([A-Z]+-[0-9]+) ]]; then
    identifier="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$identifier" ]]; then
    local stats tokens live_cost
    stats=$(fetch_issue_stats "$identifier")
    tokens=$(printf '%s' "$stats" | cut -d'|' -f1)
    live_cost=$(printf '%s' "$stats" | cut -d'|' -f2)

    local f2 f3 f4 f5 f8
    f2=$(printf '%s' "$row" | cut -d'|' -f2)   # Agent
    f3=$(printf '%s' "$row" | cut -d'|' -f3)   # Model
    f4=$(printf '%s' "$row" | cut -d'|' -f4)   # Probe
    f5=$(printf '%s' "$row" | cut -d'|' -f5)   # Pickup Latency
    f8=$(printf '%s' "$row" | cut -d'|' -f8)   # Errors

    echo "|${f2}|${f3}|${f4}|${f5}| ${tokens} | ${live_cost} |${f8}|"
  else
    echo "$row"
  fi
}

# ---------------------------------------------------------------------------
# Helper: collect rows for a single already-done probe using pre-fetched data.
# Appends rows to stdout; caller accumulates into a variable.
# Usage: collect_probe_rows <probe_json> <comments_json> <stats_str>
# ---------------------------------------------------------------------------
collect_probe_rows() {
  local probe_json="$1" comments_json="$2" stats_str="$3"
  local p_identifier p_agent p_link p_tokens p_cost p_model
  p_identifier=$(printf '%s' "$probe_json" | jq -r '.identifier // "?"')
  p_agent=$(printf '%s' "$probe_json" | jq -r '.title // "?"' | sed 's/^Rollcall Probe - //')
  p_link=$(make_issue_link "$p_identifier")
  p_tokens=$(printf '%s' "$stats_str" | cut -d'|' -f1)
  p_cost=$(printf '%s' "$stats_str" | cut -d'|' -f2)

  local results_body
  results_body=$(printf '%s' "$comments_json" | jq -r \
    '[.[] | select(.body | contains("## Rollcall Results")) | select(.body | test("(?m)^[|]"))] | sort_by(.createdAt) | last | .body // empty' \
    2>/dev/null || echo "")

  if [[ -n "$results_body" ]]; then
    local data_rows
    data_rows=$(printf '%s' "$results_body" \
      | grep '^|' \
      | grep -v '^|[-|[:space:]]*$' \
      | grep -vi '^| *agent *|' \
      | grep -vi '^| *\*\*total\*\* *|' \
      || true)
    if [[ -n "$data_rows" ]]; then
      while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        local row_probe_col
        row_probe_col=$(printf '%s' "$row" | cut -d'|' -f4)
        if [[ "$row_probe_col" == *"$p_identifier"* ]]; then
          # Own row: preserve model already embedded by the probe; refresh cost only.
          local f2 f3 f5 f8
          f2=$(printf '%s' "$row" | cut -d'|' -f2)   # Agent
          f3=$(printf '%s' "$row" | cut -d'|' -f3)   # Model (probe determined at runtime)
          f5=$(printf '%s' "$row" | cut -d'|' -f5)   # Pickup Latency
          f8=$(printf '%s' "$row" | cut -d'|' -f8)   # Errors
          echo "|${f2}|${f3}| ${p_link} |${f5}| ${p_tokens} | ${p_cost} |${f8}|"
        else
          # Sub-probe row: refresh costs.
          update_row_stats "$row"
        fi
      done <<< "$data_rows"
      return
    fi
  fi

  # Fallback: no results comment — build from pre-fetched metadata and stats.
  local p_created p_started p_pickup
  p_created=$(printf '%s' "$probe_json" | jq -r '.createdAt // empty')
  p_started=$(printf '%s' "$probe_json" | jq -r '.startedAt // empty')
  p_pickup=$(compute_pickup_latency "$p_created" "$p_started")
  echo "| ${p_agent} | - | ${p_link} | ${p_pickup} | ${p_tokens} | ${p_cost} | - |"
}

# ---------------------------------------------------------------------------
# 1. List direct reports (scoped: reportsTo == me)
# ---------------------------------------------------------------------------
echo "[rollcall] fetching direct reports..." >&2
reports=$(bash "$SCRIPT_DIR/agent-list-reports.sh" "$AGENT_ID") \
  || { echo "ERROR: agent-list-reports.sh failed" >&2; exit 1; }

report_count=$(printf '%s' "$reports" | jq 'length')
echo "[rollcall] direct reports: $report_count" >&2


# ---------------------------------------------------------------------------
# 2. No reports → leaf node: post own 1-row results table, set done
# ---------------------------------------------------------------------------
if [[ "$report_count" -eq 0 ]]; then
  echo "[rollcall] no direct reports — posting leaf latency row" >&2

  # Fetch own issue to compute pickup latency (createdAt -> startedAt)
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
  own_model=$(fetch_own_model "$own_issue")

  comment=$(cat <<MD
## Rollcall Results

| Agent | Model | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|---|
| ${own_agent} | ${own_model} | ${own_link} | ${own_pickup} | ${own_tokens} | ${own_cost} | - |
MD
)

  bash "$SCRIPT_DIR/agent-comment.sh" "$TASK_ID" "$comment" >/dev/null \
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

  # Determine model profile to stamp on probe issues.
  # Priority:
  #   1. assigneeAdapterOverrides.modelProfile on own issue — set by parent when
  #      this issue is itself a probe (recursive propagation).
  #   2. (model:<value>) directive in own issue title — human entry point for the
  #      root rollcall issue (e.g. "Rollcall (model:cheap)").
  own_issue_b=$(api_get "/api/issues/$TASK_ID" 2>/dev/null || echo "{}")
  PROBE_MODEL_PROFILE=$(printf '%s' "$own_issue_b" \
    | jq -r '.assigneeAdapterOverrides.modelProfile // empty' 2>/dev/null || echo "")

  if [[ -z "$PROBE_MODEL_PROFILE" ]]; then
    own_title=$(printf '%s' "$own_issue_b" | jq -r '.title // empty' 2>/dev/null || echo "")
    _directive_value=$(printf '%s' "$own_title" \
      | grep -oP '(?<=\(model:)[^)]+(?=\))' \
      | head -n 1 || echo "")
    case "$_directive_value" in
      cheap)   PROBE_MODEL_PROFILE="cheap" ;;
      default) PROBE_MODEL_PROFILE="" ;;
      "")      PROBE_MODEL_PROFILE="" ;;
      *)       echo "[rollcall] WARNING: unrecognised modelProfile directive '$_directive_value', using default" >&2 ;;
    esac
  fi

  if [[ -n "$PROBE_MODEL_PROFILE" ]]; then
    echo "[rollcall] probe model profile: $PROBE_MODEL_PROFILE" >&2
  else
    echo "[rollcall] probe model profile: default" >&2
  fi

  probe_ids=()

  while IFS= read -r report; do
    r_id=$(printf '%s' "$report" | jq -r '.id')
    r_name=$(printf '%s' "$report" | jq -r '.name')
    echo "[rollcall]   creating probe for $r_name ($r_id)..." >&2

    # agent-rollcall-probe.sh is idempotent; safe to call even on re-entry
    probe_args=(--agent-id "$r_id" --agent-name "$r_name" --parent "$TASK_ID")
    [[ -n "$PROBE_MODEL_PROFILE" ]] && probe_args+=(--model-profile "$PROBE_MODEL_PROFILE")

    probe_output=$(bash "$SCRIPT_DIR/agent-rollcall-probe.sh" "${probe_args[@]}") \
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

    echo "[rollcall]   probe for $r_name -> id=$probe_id" >&2
    probe_ids+=("$probe_id")
  done < <(printf '%s' "$reports" | jq -c '.[]')

  # Build JSON array of probe ids for declarative blocker set
  blocker_array=$(printf '%s\n' "${probe_ids[@]}" | jq -R . | jq -sc .)

  # Optimistically collect rows for any probes that are already done.
  # Results are cached in a comment on this issue so State D can use them
  # on resume without re-querying — same code path whether suspended or not.
  echo "[rollcall] collecting rows from any already-done probes..." >&2
  _cached_rows=""
  _cached_probe_ids=()
  _probe_jsons=()
  _all_done=true

  for _pid in "${probe_ids[@]}"; do
    _resp=$(api_get "/api/issues/$_pid" 2>/dev/null || echo "{}")
    _status=$(printf '%s' "$_resp" | jq -r '.status // empty')

    if [[ "$_status" != "done" ]]; then
      echo "[rollcall]   probe $_pid not yet done (status=${_status:-unknown}) — stopping optimistic collection" >&2
      _all_done=false
      break
    fi

    echo "[rollcall]   probe $_pid already done; collecting rows..." >&2
    _probe_jsons+=("$_resp")
    _p_identifier=$(printf '%s' "$_resp" | jq -r '.identifier // "?"')
    _p_comments=$(api_get "/api/issues/$_pid/comments" 2>/dev/null || echo "[]")
    _p_stats=$(fetch_issue_stats "$_pid")

    while IFS= read -r _row; do
      _cached_rows="${_cached_rows}${_row}"$'\n'
    done < <(collect_probe_rows "$_resp" "$_p_comments" "$_p_stats")

    _cached_probe_ids+=("$_p_identifier")
    echo "[rollcall]   $_p_identifier: rows cached" >&2
  done

  # Post cache comment so State D can consume pre-fetched rows on resume.
  if [[ ${#_cached_probe_ids[@]} -gt 0 ]]; then
    _probe_list=$(printf '%s,' "${_cached_probe_ids[@]}" | sed 's/,$//')
    _cache_body="<!-- rollcall-row-cache probes:${_probe_list} -->"$'\n'"${_cached_rows}"
    bash "$SCRIPT_DIR/agent-comment.sh" "$TASK_ID" "$_cache_body" >/dev/null \
      || { echo "ERROR: Failed to post row cache comment" >&2; exit 1; }
    echo "[rollcall] row cache posted for: $_probe_list" >&2
  fi

  if [[ "$_all_done" == true ]]; then
    echo "[rollcall] all probes already done; skipping blocked" >&2
    bash "$SCRIPT_DIR/agent-comment.sh" "$TASK_ID" \
      "All probe issues completed before this issue could be set to blocked. Proceeding directly to aggregation." \
      >/dev/null || { echo "ERROR: Failed to post aggregation notice" >&2; exit 1; }
    # Populate existing_probes from collected JSONs so State C/D can proceed.
    existing_probes=$(printf '%s\n' "${_probe_jsons[@]}" | jq -s '.')
    # Fall through — State C's all_terminal check passes, State D runs.
  else
    echo "[rollcall] registering blockers: $blocker_array" >&2
    set_self_status "blocked" "$blocker_array"
    echo "[rollcall] probes created and registered; exiting (Paperclip will re-wake)" >&2
    exit 0
  fi
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
# Read the row cache posted by State B. If present, rows for cached probes are
# used directly without re-querying their comments or costs. Uncached probes
# (arrived done after suspend) are fetched as normal. update_row_stats is only
# applied to fresh rows — cached rows already carry current costs.
echo "[rollcall] State D: all probes terminal — collating results" >&2

# Read row cache (posted in State B if any probes were done pre-suspend/pre-fallthrough).
_cached_rows=""
_cached_probe_ids=()
own_comments=$(api_get "/api/issues/$TASK_ID/comments" 2>/dev/null || echo "[]")
_cache_body=$(printf '%s' "$own_comments" | jq -r \
  '[.[] | select(.body | startswith("<!-- rollcall-row-cache"))] | last | .body // empty' \
  2>/dev/null || echo "")
if [[ -n "$_cache_body" ]]; then
  _cache_header=$(printf '%s' "$_cache_body" | head -n 1)
  if [[ "$_cache_header" =~ probes:([^[:space:]>]+) ]]; then
    IFS=',' read -ra _cached_probe_ids <<< "${BASH_REMATCH[1]}"
  fi
  _cached_rows=$(printf '%s' "$_cache_body" | tail -n +2)
  echo "[rollcall] row cache covers: ${_cached_probe_ids[*]:-none}" >&2
fi

# Self-row: include only when this issue is itself a rollcall_probe
# (intermediate node). The root trigger (routine_execution) is the orchestrator
# and is not itself a measured report.
own_issue=$(api_get "/api/issues/$TASK_ID") \
  || { echo "ERROR: Failed to fetch own issue" >&2; exit 1; }
own_origin_kind=$(printf '%s' "$own_issue" | jq -r '.originKind // empty')

fresh_rows=""
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
  own_model=$(fetch_own_model "$own_issue")
  fresh_rows="| ${own_agent} | ${own_model} | ${own_link} | ${own_pickup} | ${own_tokens} | ${own_cost} | - |"$'\n'
  echo "[rollcall] self-row: $own_agent model=${own_model} pickup=${own_pickup} tokens=${own_tokens} cost=${own_cost}" >&2
fi

# Collate rows from each probe not already covered by the cache.
while IFS= read -r probe; do
  p_id=$(printf '%s' "$probe" | jq -r '.id // empty')
  p_identifier=$(printf '%s' "$probe" | jq -r '.identifier // "?"')
  p_status=$(printf '%s' "$probe" | jq -r '.status // "unknown"')
  p_agent=$(printf '%s' "$probe" | jq -r '.title // "?"' | sed 's/^Rollcall Probe - //')
  p_link=$(make_issue_link "$p_identifier")

  if [[ -z "$p_id" ]]; then continue; fi

  # Skip probes whose rows were already collected and cached in State B.
  for _cid in "${_cached_probe_ids[@]:-}"; do
    if [[ "$_cid" == "$p_identifier" ]]; then
      echo "[rollcall]   $p_agent: using cached rows" >&2
      continue 2
    fi
  done

  # Fetch the probe issue's comments; find the most recent Rollcall Results block
  probe_comments=$(api_get "/api/issues/$p_id/comments" 2>/dev/null || echo "[]")
  results_body=$(printf '%s' "$probe_comments" | jq -r \
    '[.[] | select(.body | contains("## Rollcall Results")) | select(.body | test("(?m)^[|]"))] | sort_by(.createdAt) | last | .body // empty' \
    2>/dev/null || echo "")

  if [[ -n "$results_body" ]]; then
    data_rows=$(printf '%s' "$results_body" \
      | grep '^|' \
      | grep -v '^|[-|[:space:]]*$' \
      | grep -vi '^| *agent *|' \
      | grep -vi '^| *\*\*total\*\* *|' \
      || true)
    if [[ -n "$data_rows" ]]; then
      row_count=$(printf '%s' "$data_rows" | wc -l | tr -d ' ')
      echo "[rollcall]   $p_agent: collated $row_count row(s) from results comment" >&2
      fresh_rows="${fresh_rows}${data_rows}"$'\n'
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
  fresh_rows="${fresh_rows}| ${p_agent} | - | ${p_link} | ${p_pickup} | ${p_tokens} | ${p_cost} | ${error_status} |"$'\n'

done < <(printf '%s' "$existing_probes" | jq -c '.[]')

# Update costs on fresh rows only (self-row + uncached probes).
# Cached rows already carry current costs fetched in State B — no re-query needed.
updated_fresh_rows=""
while IFS= read -r row; do
  if [[ -n "$row" ]]; then
    updated_row=$(update_row_stats "$row")
    updated_fresh_rows="${updated_fresh_rows}${updated_row}"$'\n'
  fi
done <<< "$fresh_rows"

table_rows="${_cached_rows}${updated_fresh_rows}"

# Compute grand total cost and tokens from all collected rows
total_tokens=$(sum_token_rows "$table_rows")
total_cost=$(sum_cost_rows "$table_rows")
echo "[rollcall] grand total tokens: $total_tokens cost: $total_cost" >&2

comment=$(cat <<MD
## Rollcall Results

| Agent | Model | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
|---|---|---|---|---|---|---|
${table_rows}| **Total** | | | | **${total_tokens}** | **${total_cost}** | |
MD
)

echo "[rollcall] posting results comment..." >&2
bash "$SCRIPT_DIR/agent-comment.sh" "$TASK_ID" "$comment" >/dev/null \
  || { echo "ERROR: Failed to post results comment" >&2; exit 1; }

set_self_status "done"
echo "[rollcall] done" >&2
exit 0
