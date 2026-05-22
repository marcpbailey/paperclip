## Thinking Path

> - Paperclip orchestrates AI agents for zero-human companies
> - The MCP Server subsystem enables agents and IDEs to execute board-level tasks locally
> - Natively executing the MCP server inside the monorepo workspace using raw Node throws `ERR_MODULE_NOT_FOUND` because local package exports point to uncompiled `.ts` source files, which raw Node cannot natively resolve.
> - This requires engineers to setup heavy transpilers just to boot the MCP server.
> - This pull request implements conditional exports for `@paperclipai/shared`, pointing `default` to the compiled `dist/*.js` artifacts while preserving `development` pointing to `src/*.ts`.
> - The benefit is that local standard Node processes (like IDE-spawned MCP servers) can seamlessly boot out-of-the-box using the built `.js` artifacts, while Vite and Vitest still hot-reload flawlessly off the `.ts` source files.

## What Changed

- Added Node conditional exports (`development` and `default`) to `packages/shared/package.json`
- Rewired `packages/mcp-server/tsconfig.json` paths to correctly resolve `@paperclipai/shared` to the compiled `dist/` directory.

## Verification

- Run `pnpm build` in the workspace.
- Execute `node packages/mcp-server/dist/stdio.js` directly. The MCP server boots silently (awaiting stdio) without crashing.
- Run `pnpm dev` and verify that hot-reloading still functions correctly for the API and UI.

## Risks

- Low risk. Conditional exports are a standard Node feature and correctly isolate the transpiler behavior from raw execution behavior. Production builds naturally overwrite exports via `publishConfig`.

## Model Used

- Google Gemini Experimental (antigravity-ide)

## Checklist

- [x] I have included a thinking path that traces from project context to this change
- [x] I have specified the model used (with version and capability details)
- [x] I have checked ROADMAP.md and confirmed this PR does not duplicate planned core work
- [x] I have run tests locally and they pass
- [x] I have added or updated tests where applicable
- [ ] If this change affects the UI, I have included before/after screenshots
- [x] I have updated relevant documentation to reflect my changes
- [x] I have considered and documented any risks above
- [x] I will address all Greptile and reviewer comments before requesting merge
