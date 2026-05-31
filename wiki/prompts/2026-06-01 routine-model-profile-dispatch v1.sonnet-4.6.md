# Routine Model Profile Dispatch

## Context

Paperclip routines create issues and assign them to agents. The issue schema has a field `assigneeAdapterOverrides` (JSONB, `packages/db/src/schema/issues.ts:51`) that can carry a `modelProfile` key. When present, the heartbeat service reads it at run time (`server/src/services/heartbeat.ts`, around line 7099) and applies the named model profile from the agent's `runtimeConfig.modelProfiles`, overriding the agent's default model for that run.

The only currently valid `ModelProfileKey` is `"cheap"` (`packages/shared/src/constants.ts`, `MODEL_PROFILE_KEYS = ["cheap"] as const`). Every agent in the LinkCast company has `modelProfiles.cheap` configured (Haiku).

The problem: `dispatchRoutineRun()` in `server/src/services/routines.ts` does not pass `assigneeAdapterOverrides` when calling `issueSvc.create()` (around line 1240). The `CreateRoutine` schema (`packages/shared/src/validators/routine.ts:52-65`) does not include the field either. There is no way to configure a routine to run its assigned agent on the cheap model without changing the agent's default globally.

The current workaround is a `(model:cheap)` directive parsed from the issue title by the `agent-rollcall` skill script. This is a stopgap, not a general solution, and it only affects child probe issues created by the script, not the top-level dispatch issue itself.

The contribution flow is: fork `marcpbailey/paperclip`, open a PR onto `paperclipai/paperclip`. The local instance runs in Docker; changes to the server require a container rebuild.

## Goal

A routine can be configured with a model profile that is stamped onto the issue it dispatches, so the assigned agent runs on the requested model for that issue without any change to the agent's global config.

## Requirements

1. The `routines` table must gain a nullable `assigneeAdapterOverrides` JSONB column (or a dedicated `modelProfile` text column) that stores the desired override.
2. `dispatchRoutineRun()` must read this field and pass it as `assigneeAdapterOverrides` on the `issueSvc.create()` call.
3. The `CreateRoutine` and `UpdateRoutine` Zod schemas must accept the new field, validated against `MODEL_PROFILE_KEYS` (currently `["cheap"]`).
4. The routine edit UI must expose a "Model profile" selector in the Advanced Delivery Settings section, with at minimum two options: "Default (no override)" and "Cheap (Haiku)". The selector must be optional, defaulting to no override.
5. The existing `(model:cheap)` title-directive workaround in `local/skills/agent-rollcall/scripts/agent-rollcall.sh` should be removed or deprecated once this feature ships and the rollcall routine has been updated.
6. A database migration must accompany the schema change.

## Approach

The simplest schema change is a `modelProfile` text column on the `routines` table (nullable, validated against `MODEL_PROFILE_KEYS`) rather than a full JSONB `assigneeAdapterOverrides`, since model profile is the only controlled field today. If future overrides (e.g. raw `adapterConfig`) are anticipated, the JSONB approach matches the issue schema exactly and is more forward-compatible.

In `dispatchRoutineRun()`, after building the issue create payload, add:
```ts
if (routine.modelProfile) {
  payload.assigneeAdapterOverrides = { modelProfile: routine.modelProfile };
}
```

The UI selector lives under the existing "Advanced Delivery Settings" section of the routine edit form. It should be a simple `<select>` or radio group, not a free-text field, to keep it constrained to valid values.

## Out of Scope

- Exposing raw `adapterConfig` overrides via the UI (arbitrary model overrides, temperature, etc.)
- Per-variable or conditional model profile selection
- Applying model profile overrides to manually triggered issues outside of routines

## Acceptance Criteria

- Creating or editing a routine with `modelProfile: "cheap"` via the API persists the value.
- When the routine fires, the dispatched issue has `assigneeAdapterOverrides: { modelProfile: "cheap" }`.
- The assigned agent's run uses the cheap model (verifiable via the run's `usageJson.model` or the heartbeat transcript `init` event).
- The UI selector appears in Advanced Delivery Settings and round-trips correctly.
- No model profile set: behaviour is identical to today (no `assigneeAdapterOverrides` on the dispatched issue).

## Open Questions

- Should the column be `modelProfile text` (simple, constrained) or `assigneeAdapterOverrides jsonb` (mirrors issue schema, more extensible)? The JSONB approach avoids a second migration if raw config overrides are added later.
- Should the `(model:cheap)` title-directive in the rollcall script be removed immediately on merge, or kept as a fallback until the routine is updated in production?

## References

- `server/src/services/routines.ts` - `dispatchRoutineRun()`, issue create call around line 1240
- `packages/shared/src/validators/routine.ts` - `CreateRoutine` schema, lines 52-65
- `packages/shared/src/constants.ts` - `MODEL_PROFILE_KEYS`
- `packages/db/src/schema/issues.ts:51` - `assigneeAdapterOverrides` on issues
- `server/src/services/heartbeat.ts` around line 7099 - override application at run time
- `local/skills/agent-rollcall/scripts/agent-rollcall.sh` - current title-directive workaround
- `local/skills/agent-rollcall/info.md` - rollcall design docs including workaround rationale
