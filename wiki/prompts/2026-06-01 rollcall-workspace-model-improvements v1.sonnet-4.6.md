# Rollcall and Workspace Improvements — Session Retrospective

This document records what was diagnosed, built, and fixed during a single session on 2026-06-01. It is a narrative of decisions made, not a spec for future work.

---

## 1. Diagnosed why agents were not reading /paperclip/AGENTS.md

**Trigger:** LINAA-910 (a simple Ping to Fury) showed Fury did not read `/paperclip/AGENTS.md`.

**Root cause:** Paperclip resolves an agent's working directory in priority order: project workspace → previous task session → agent home fallback. Projectless issues (routine-dispatched pings, rollcalls) fell through to the agent home fallback at `/paperclip/instances/default/workspaces/{agentId}`. This UUID-named directory is not under the company tree, so Claude Code's `AGENTS.md` auto-loading never reached `/paperclip/AGENTS.md`.

Upstream blockers:
- Issue #1425 (open): no per-agent workspace path field
- Bug #2443 (open): `instructionsRootPath` in `adapterConfig` is not used as cwd

**Fix: symlinks.** `local/bin/link-agent-workspaces.sh` replaces each agent's UUID fallback directory with a symlink to their company workspace:
```
/paperclip/instances/default/workspaces/{agentId}
  → /paperclip/companies/linkcast/agents/{name}
```
The harness still records the UUID path, but the OS resolves through the symlink. All 11 agents were linked. Run in the container:
```
docker exec paperclip-linkcast-server-1 bash /paperclip/companies/linkcast/agents/link-agent-workspaces.sh
```

**Fix: explicit include.** `local/bin/prepend-agents-include.sh` prepends `@/paperclip/AGENTS.md` to every agent's `AGENTS.md`, making the include explicit and load-order-guaranteed regardless of cwd resolution. All 11 agents updated.

**Verified** with LINAA-913 (Ping to Stark): `pwd` showed `/paperclip/companies/linkcast/agents/stark`, and Stark quoted both his own AGENTS.md and `/paperclip/AGENTS.md` correctly.

**Caveat:** Both fixes live inside the container volume and are lost on rebuild. The scripts need to be re-run after any container rebuild.

---

## 2. Diagnosed and fixed rollcall agent improvisation on re-wake

**Observed:** In rollcall runs, intermediate agents (Natasha, Nebula) were posting `## Rollcall Complete` comments instead of the canonical `## Rollcall Results` table. Parent agents (Fury, Stark) use `contains("## Rollcall Results")` to find sub-agent results, so improvised comments were invisible to aggregation. Parents fell through to the single-row fallback, giving Fury a 2-row table instead of the full org chart.

**Root cause:** On re-wake, the context payload includes `childIssueSummaries` with all sub-probe results already populated. Agents saw this, decided they had everything they needed, and wrote their own summary — exactly what a thoughtful agent would do in most contexts, but fatal here.

**Fix:** `local/skills/agent-rollcall/SKILL.md` — the `On Re-Wake` section was strengthened to explicitly prohibit this pattern:
- Names the exact anti-pattern (`## Rollcall Complete`)
- States that `childIssueSummaries` in the re-wake context must not be used for manual processing
- Repeats the exact command to run
- Explains why hand-composed output breaks parent aggregation

---

## 3. Added title-based model profile selection to rollcall

**Problem:** All rollcall runs were using Opus for every agent, costing ~$5 per run. The probes are trivial smoke tests; Haiku is sufficient.

**Mechanism:** Issues have an `assigneeAdapterOverrides` field that can carry `{modelProfile: "cheap"}`. When set, the heartbeat service applies the agent's `cheap` model profile (all agents have Haiku configured). Routines cannot set this field (gap in the dispatch API — documented in `wiki/prompts/2026-06-01 routine-model-profile-dispatch v1.sonnet-4.6.md` as a future PR).

**Workaround:** The routine title carries the directive. Format: `Rollcall (model:cheap)` or `Rollcall (model:default)`. The directive is opaque to agents (it reads as a label, not an instruction) and visible to humans in the issue list.

**Script changes:**
- `agent-create-issue.sh`: added `--adapter-overrides <json>` flag, included in payload as `assigneeAdapterOverrides`
- `agent-rollcall-probe.sh`: added `--model-profile <value>` flag, constructs and passes adapter overrides JSON
- `agent-rollcall.sh` State B: reads model profile from own issue's `assigneeAdapterOverrides.modelProfile` first (set by parent for recursive propagation), falls back to title directive for the root issue. Passes profile to all sub-probe creation calls.

**Recursive propagation:** Because Fury stamps `assigneeAdapterOverrides` on Stark and Natasha's probe issues, and those agents read it from their own issue before checking the title, the cheap model propagates through the full tree automatically. Probe titles never carry the directive — they always read `Rollcall Probe - {name}`.

---

## 4. Added Model column to rollcall results table

**Change:** Results table gained a `Model` column between Agent and Probe:
```
| Agent | Model | Probe | Pickup Latency | Tokens (In/Cached/Out) | Cost | Errors |
```

**Design:** Each probe determines its own model at runtime via `fetch_own_model()`, which reads `assigneeAdapterOverrides.modelProfile` from its own issue and resolves it against its own agent config (`GET /api/agents/{id}`). The model name is shortened (e.g. `claude-haiku-4-5-20251001` → `haiku.4.5`). It is embedded in the results comment the probe posts. Parent agents read it verbatim — no model lookups in the aggregation path.

Fallback rows (cancelled probes, missing results comments) show `-` for model.

**Column index updates:** All helpers updated for the new 7-column layout: `sum_token_rows` (tokens now col 6), `sum_cost_rows` (cost now col 7), `update_row_stats` (probe identifier now col 4), `collect_probe_rows` (own-row and sub-row handling updated).

---

## 5. Fixed unbound variable crash in fetch_own_model

**Bug:** `local model_profile model agent_resp` declared variables without initialising them. With `set -u`, reading `$model` before the first `if` block ran (when `model_profile` was empty) triggered `model: unbound variable`.

**Fix:** Changed to `local model_profile="" model="" agent_resp=""`.

---

## 6. Fixed model directive not propagating recursively

**Bug:** The model directive was read from the issue title. Probe issues are titled `Rollcall Probe - {name}` — no directive. So intermediate nodes (Natasha, Stark) saw no directive and created sub-probes without the model profile.

**Fix:** State B now reads `assigneeAdapterOverrides.modelProfile` from the own issue first (set by the parent during probe creation). Only if that is absent does it fall back to the title directive. This ensures the root rollcall sets the model via title, and every recursive level propagates it via `assigneeAdapterOverrides`.

---

## 7. Added defensive || true to grep chains

**Bug (unconfirmed):** In LINAA-972, the script crashed in State D after collating Stark's rows, before processing Natasha's rows. No `ERROR:` line was emitted, suggesting `set -euo pipefail` killed the script silently. The `data_rows` grep pipeline (four chained `grep` calls inside `$(...)`) returns exit code 1 if any stage produces no output — with `pipefail` this propagates as a script-fatal error.

**Fix:** Added `|| true` to both `data_rows` grep chain locations (State D inline loop and `collect_probe_rows`). This ensures "no rows found" is treated as an empty result rather than a fatal error.

**Debug instrumentation added** (temporary): `[rollcall:dbg]` log lines around the State D grep chain log line counts after each filter stage, to pinpoint the exact failure on the next run. Remove after diagnosis by deleting all lines containing `[rollcall:dbg]`.

---

## 8. Companion documentation

- `local/skills/agent-rollcall/info.md` (new): theory of operation, state machine, key design properties, race condition fix, workspace symlink rationale, why each hard rule exists
- `local/skills/agent-rollcall/SKILL.md`: trimmed from ~99 lines to ~45 — removed state machine description, results table format, and environment table (all moved to info.md); hardened re-wake instructions
- `wiki/prompts/2026-06-01 routine-model-profile-dispatch v1.sonnet-4.6.md`: spec for upstream PR to add `assigneeAdapterOverrides` to routine dispatch + UI exposure

---

## Scripts created

| Script | Purpose |
|---|---|
| `local/bin/link-agent-workspaces.sh` | Symlinks UUID workspace dirs to company agent dirs (run in container) |
| `local/bin/prepend-agents-include.sh` | Prepends `@/paperclip/AGENTS.md` to all agent AGENTS.md files (run in container) |
