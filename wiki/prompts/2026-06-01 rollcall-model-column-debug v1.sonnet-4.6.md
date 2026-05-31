# Rollcall Model Column — Debug Continuation

## Context

The `agent-rollcall` skill in `local/skills/agent-rollcall/` orchestrates a recursive org-chart health check. A session of work added two features to the rollcall script (`local/skills/agent-rollcall/scripts/agent-rollcall.sh`):

1. **Title-based model selection** — the routine title can include `(model:cheap)` or `(model:default)`. The script reads this directive from the root issue title (for the top-level rollcall) or from `assigneeAdapterOverrides.modelProfile` on the probe issue (for recursive intermediate nodes). It propagates the profile to all probe issues via `--model-profile` on `agent-create-issue.sh`.

2. **Model column in results table** — each agent's results row now includes the model it actually ran on, determined at runtime by `fetch_own_model()`. The probe embeds the model name in its own results comment; the parent reads it verbatim. Table format: `| Agent | Model | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |`

The scripts are live-mounted read-only into the container at `/app/skills/agent-rollcall/` from `local/skills/agent-rollcall/` on the host. Changes take effect immediately without a container rebuild.

## Current State

### What works

- `agent-create-issue.sh` accepts `--adapter-overrides <json>` and includes it as `assigneeAdapterOverrides` in the issue create payload
- `agent-rollcall-probe.sh` accepts `--model-profile <value>` and passes `{"modelProfile":"<value>"}` as adapter overrides
- `agent-rollcall.sh` State B reads model profile from own issue (`assigneeAdapterOverrides.modelProfile` takes priority, title directive is fallback), then propagates to sub-probes
- `fetch_own_model()` helper in `agent-rollcall.sh` fetches own agent config and resolves actual model name; `shorten_model_name()` formats it (e.g. `haiku.4.5`)
- Column indices updated throughout (`sum_token_rows` uses col 6 for tokens, col 7 for cost; `update_row_stats` uses col 4 for probe identifier)
- SKILL.md updated to explicitly prohibit improvising on re-wake (agents were posting `## Rollcall Complete` instead of running the script)

### Active bug: State D crash with exit code 1

Run LINAA-972 failed during State D (Fury aggregating results). Script output:

```
[rollcall] State D: all probes terminal — collating results
[rollcall]   Stark: collated 7 row(s) from results comment
exit code: 1
```

Stark's 7 rows were collated successfully. The script then crashed silently (no `ERROR:` line) while processing Natasha's probe. Natasha's probe (LINAA-974) has a valid `## Rollcall Results` comment in the correct 7-column format with 2 data rows (Natasha + Loki). The crash has no visible log output, suggesting `set -euo pipefail` killed the script rather than an explicit `exit 1`.

**Hypothesis (unconfirmed):** `grep` returning exit code 1 (no matches) inside `$()` with `set -euo pipefail` caused the script to exit. This would happen if any grep in the `data_rows` pipeline found no matching lines.

**Defensive fix already applied:** `|| true` added to both `data_rows` grep chain locations (State D inline loop and `collect_probe_rows`).

**Debug instrumentation added to State D inline loop** — the next run will emit `[rollcall:dbg]` lines showing the comments fetch result, `results_body` length, and line counts after each grep filter stage. This will pinpoint the exact failure location.

### Other known issues fixed this session

- `model: unbound variable` bug in `fetch_own_model()` — fixed by initialising `local model_profile="" model="" agent_resp=""`
- Model directive not propagating recursively — fixed by reading `assigneeAdapterOverrides.modelProfile` from own issue (set by parent) before falling back to title directive
- `shorten_model_name` produces `haiku.4.5` (dots) rather than `haiku-4.5` (hyphens) — cosmetic only, not yet fixed

## What to do next

1. Check the final output by again running skill `/trace-issue-run LINAA-972`
2. If step 1 proves inconclusive, ask the user to trigger a new rollcall run with the routine title `Rollcall (model:cheap)`.
3. Once the run completes (or crashes), trace the run using `/trace-issue-run <identifier>` and examine the `[rollcall:dbg]` output to identify the exact crash location.
4. Based on findings, either confirm the `|| true` fix resolved the crash, or identify the actual failing line and fix it.
5. Once a clean run completes, remove the `[rollcall:dbg]` instrumentation from `agent-rollcall.sh` (search for `[rollcall:dbg]` to find all lines).
6. Verify the final results table shows correct model names for all agents, and that the model propagates recursively (intermediate nodes like Stark and Natasha should show cheap model, not default).

## Key files

- `local/skills/agent-rollcall/scripts/agent-rollcall.sh` — main orchestrator
- `local/skills/agent-rollcall/scripts/agent-rollcall-probe.sh` — probe creator (accepts `--model-profile`)
- `local/skills/agent-rollcall/scripts/agent-create-issue.sh` — issue creator (accepts `--adapter-overrides`)
- `local/skills/agent-rollcall/SKILL.md` — agent-facing instructions
- `local/skills/agent-rollcall/info.md` — theory of operation (reference only)
- `local/bin/paperclip-api.sh` — authenticated API helper (requires `op run`)

## API / diagnosis commands

```bash
# Fetch issue
local/bin/paperclip-api.sh GET /api/issues/LINAA-xxx

# Fetch run transcript (parse for key events)
local/bin/paperclip-api.sh GET /api/heartbeat-runs/<runId>/log \
  | python3 -c "
import json,sys
data=json.load(sys.stdin)
for line in data.get('content','').split('\n'):
    try:
        e=json.loads(line)
        chunk=e.get('chunk','')
        if '[rollcall]' in chunk or 'ERROR' in chunk:
            print(chunk.strip())
    except: pass
"
```
