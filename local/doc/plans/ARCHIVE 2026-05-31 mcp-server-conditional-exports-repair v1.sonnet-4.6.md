# ARCHIVE 2026-05-31 mcp-server-conditional-exports-repair v1.sonnet-4.6

## Context

Project: `paperclip` monorepo at `/Users/marc/Projects/paperclip`
Working worktree: `/Users/marc/Projects/paperclip/.claude/worktrees/mcp-conditional-exports-fix`
Worktree branch: `worktree-mcp-conditional-exports-fix`, based on `origin/master` at `911a1e8b0`

**Prime directive:** never modify origin source on main directly. All fixes go via fork branch + cherry-pick only.

Repo structure: pnpm workspace with ~30 packages. Upstream is `paperclipai/paperclip` (origin). Marc's fork is at `marcpbailey/paperclip` (fork remote). A LinkCast fork is tracked as `paperclip` remote. All forks follow a cherry-pick workflow: changes land on main via `revert + cherry-pick` of corrected commits, never direct edits.

`packages/mcp-server` is a standalone MCP server package. `packages/shared` is the shared utilities package imported by most other packages. Both use NodeNext module resolution. TypeScript version in use is 5.9.3.

## Goal

`pnpm build` must pass cleanly from a clean install (no pre-existing `dist/` artifacts), both locally and in CI, without breaking the ability to run `node dist/stdio.js` as a standalone MCP server process.

## Root Cause

Commit `6bf9a79b5` ("fix(mcp): add conditional exports for local raw node execution") introduced two changes that together cause the build to fail:

**Change 1 -- `packages/shared/package.json` exports (substantive, correct intent):**
Restructured `exports` from flat `.ts` source paths to a conditional map:
- `development` condition: `./src/index.ts` (and telemetry, wildcard equivalents)
- `default` condition: `./dist/index.js` (and equivalents)

The goal was to allow `node dist/stdio.js` to resolve `@paperclipai/shared` to built JS at runtime, rather than TypeScript source that Node cannot execute.

**Change 2 -- `packages/mcp-server/tsconfig.json` paths block (defensive, harmful):**
Added a `paths` block mapping `@paperclipai/shared` directly to `../shared/dist/index.js`.

With NodeNext resolution, when a `paths` substitution resolves to a `.js` file, TypeScript treats it as the final resolution and never looks for the adjacent `.d.ts`. The result is `TS7016: Could not find a declaration file for module '@paperclipai/shared'`, and every Zod schema import becomes `unknown`, causing a cascade of `TS2345` errors at `src/tools.ts` lines 463, 465, 488, 500, 512.

Without the `paths` block, TypeScript resolves via the pnpm symlink through `shared`'s package exports, matches the `default` condition, finds `dist/index.js`, and then finds the adjacent `dist/index.d.ts` correctly.

**Second problem discovered during worktree verification:**
The conditional exports change in `packages/shared/package.json` also breaks the build bootstrap. `pnpm build` runs `preflight:workspace-links` first, which invokes tsx scripts that import `@paperclipai/shared`. With `default` pointing to `./dist/index.js`, tsx resolves to `dist/` before anything is built, crashing with `ERR_MODULE_NOT_FOUND`. Marc's local main only appeared to work because `packages/shared/dist/` was left over from prior builds. Passing `--conditions=development` to node does not help because tsx has its own resolver that ignores the flag.

The commit exists on main, `fork/feat-mcp-conditional-exports` (530486aef), and `fork/fork/feat-mcp-conditional-exports` (cd473ea91), but not on `origin/master`. Upstream builds cleanly because their exports still point directly at `.ts` source.

## Current Worktree State

`packages/shared/package.json` has been edited in the worktree to apply the conditional exports (Change 1 above). `pnpm install --frozen-lockfile` completed successfully. `pnpm build` has not been re-run since the edit; the bootstrap failure described above is expected to reproduce if run now.

## Options Considered

**(A) Keep conditional exports, pre-build shared during install.**
Add `"postinstall": "tsc"` to `packages/shared/package.json`. Solves bootstrap by ensuring `dist/` exists before any scripts run. Adds install-time tsc cost for all contributors. Touch point is `packages/shared`, which is upstream-owned.

**(B) Bundle mcp-server with tsup/esbuild.**
Emit a self-contained `dist/stdio.js` with `@paperclipai/shared` inlined. No change to `packages/shared/package.json` needed; revert it to the upstream state. The `paths` block in mcp-server's tsconfig is also removed. `packages/adapters/openrouter-agent` already uses tsup, so there is precedent. Change is entirely contained within `packages/mcp-server`.

**(C) Revert `6bf9a79b5` entirely on main.**
The published npm package's `publishConfig` already has correct exports. Dev usage already works via tsx. If the standalone raw-node execution use case is not yet required, the safest path is full revert while the correct approach is figured out.

## Approach

Confirm the correct option with Marc before acting. Previous session's recommendation was (B) as smallest blast radius, but the question of what the commit was originally trying to achieve was not fully answered before the session was killed.

Once option is confirmed:

If (B): revert `packages/shared/package.json` in the worktree to its `origin/master` state, add tsup to `packages/mcp-server`, configure `tsup.config.ts` to bundle `src/stdio.ts` as the entry point, verify `pnpm build` passes clean from a fresh install state (delete `dist/` in shared and mcp-server before running), then proceed to git steps below.

If (A): keep the current worktree state for `packages/shared/package.json`, remove the `paths` block from `packages/mcp-server/tsconfig.json`, add `"postinstall": "tsc"` to `packages/shared/package.json`, verify clean build, then proceed.

If (C): revert the worktree to `origin/master` state for both files, verify clean build, proceed.

## Git Steps (after verification passes)

1. In the worktree, commit the corrected fix with a clear message scoped to what actually changed.
2. Push the worktree branch to `fork` as a focused single-commit PR branch targeting `origin/master`. The branch should contain only the fix commit, no unrelated LinkCast commits. Open a PR to `paperclipai/paperclip`.
3. On `main`: revert `6bf9a79b5` with `git revert 6bf9a79b5 --no-commit`, then cherry-pick the corrected commit from the worktree branch. Squash or separate commits per Marc's preference.
4. Repeat step 3 for `paperclip/main` (LinkCast fork).
5. The stale branches `fork/feat-mcp-conditional-exports` and `fork/fork/feat-mcp-conditional-exports` can be deleted later; they are not the canonical PR.

Note: `gh` is 1Password-shimmed in this environment. Marc handles GitHub PR creation manually.

## Out of Scope

- Changes to any other package in the monorepo.
- Modifying how other adapters or packages import `@paperclipai/shared`.
- Resolving the question of why the original commit was authored without verifying the bootstrap case.

## Acceptance Criteria

1. `rm -rf packages/shared/dist packages/mcp-server/dist && pnpm install --frozen-lockfile && pnpm build` completes without errors from a clean checkout of the fix commit.
2. `packages/mcp-server/src/tools.ts` compiles without TS7016 or TS2345 errors.
3. `node packages/mcp-server/dist/stdio.js` runs without a module resolution error (the original motivation for the commit).
4. The fix commit is clean against `origin/master` with no unrelated changes.

## Open Questions

- Which of options A, B, or C is correct given the full intent of the original commit? Marc did not confirm before the session ended.
- Was `node dist/stdio.js` standalone execution ever actually working after `6bf9a79b5` was committed, or was it always broken locally (bootstrapped by stale dist)?
- Does the upstream PR process require a passing CI run on the PR branch, and if so, does option B introduce any CI setup changes needed for tsup?

## References

- Broken commit: `6bf9a79b5` ("fix(mcp): add conditional exports for local raw node execution"), May 23 2026
- Stale PR branches: `fork/feat-mcp-conditional-exports` (530486aef), `fork/fork/feat-mcp-conditional-exports` (cd473ea91)
- Upstream clean state: `origin/master` at `911a1e8b0`
- tsup precedent in repo: `packages/adapters/openrouter-agent`
- NodeNext + paths + .js resolution behaviour: TypeScript docs, "Module Resolution" section
