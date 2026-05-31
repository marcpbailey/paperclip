# SPEC PR_7528 mcp-container-packaging-fix

This is the doc for https://github.com/paperclipai/paperclip/pull/7258
## Thinking Path

> - Paperclip orchestrates AI agents for zero-human companies
> - It ships an MCP server (`@paperclipai/mcp-server`) so users can connect Claude Desktop and other MCP clients to their Paperclip instance
> - The MCP server binary (`dist/stdio.js`) must run standalone — outside the pnpm workspace where it was built (e.g. in a Docker container, or installed globally from source)
> - After `tsc` compiles `src/stdio.ts`, the output still contains `import '@paperclipai/shared'`; at runtime Node follows the pnpm symlink, hits the `exports` field pointing at `./src/index.ts`, and crashes — it cannot execute TypeScript
> - This PR switches the mcp-server build from `tsc` to `tsup`, which bundles `@paperclipai/shared` directly into `dist/stdio.js` so Node has nothing external to resolve
> - The benefit is that `node dist/stdio.js` works correctly in any environment — container, global install from source, or workspace — without modifying any shared or upstream package

## What Changed

- `packages/mcp-server/package.json` — build script changed from `tsc` to `tsup`; `tsup ^8.0.0` added to `devDependencies`
- `packages/mcp-server/tsup.config.ts` — new file; two-entry config:
  - `src/index.ts` → `dist/index.js` + `dist/index.d.ts` (library, `@paperclipai/shared` external — correct for npm publish)
  - `src/stdio.ts` → `dist/stdio.js` (standalone binary, `@paperclipai/shared` bundled)
- `pnpm-lock.yaml` — updated to add tsup as importer for `packages/mcp-server`

`packages/shared/package.json` is **not changed**.

## Verification

```bash
# Clean build from scratch
rm -rf packages/shared/dist packages/mcp-server/dist
pnpm install --frozen-lockfile
pnpm build
# Expected: all packages build with no errors

# Type checking
pnpm --filter @paperclipai/mcp-server typecheck
# Expected: exits 0, no TS errors

# Standalone execution (the previously failing case)
node packages/mcp-server/dist/stdio.js
# Expected: starts cleanly, exits 0 (no ERR_MODULE_NOT_FOUND)
```

## Risks

- Low risk. The change is entirely contained within `packages/mcp-server`. No other packages are modified.
- `tsup` is already used in this monorepo (`packages/adapters/openrouter-agent`) and is already resolved in `pnpm-lock.yaml`, so there is no new dependency to vet.
- The library entry (`dist/index.js` + `dist/index.d.ts`) is unchanged in shape — tsup produces the same module format as `tsc` for this entry.
- `tsc --noEmit` (typecheck) is preserved as a separate script, so strict type checking is not lost.

## Model Used

- **Provider:** Anthropic  
- **Model:** Claude Sonnet 4.6 (`claude-sonnet-4-6`)  
- **Interface:** Claude Code CLI (interactive, tool-use mode)  
- **Capabilities used:** file read/edit, shell execution, git operations, multi-turn reasoning across a worktree-isolated branch

## Checklist

- [x] I have included a thinking path that traces from project context to this change
- [x] I have specified the model used (with version and capability details)
- [x] I have checked ROADMAP.md and confirmed this PR does not duplicate planned core work
- [x] I have run tests locally and they pass
- [ ] I have added or updated tests where applicable *(no test changes needed — this is a build tooling fix with no logic change)*
- [ ] If this change affects the UI, I have included before/after screenshots *(N/A — no UI change)*
- [ ] I have updated relevant documentation to reflect my changes *(N/A — no public API or behaviour change)*
- [x] I have considered and documented any risks above
- [x] I will address all Greptile and reviewer comments before requesting merge
