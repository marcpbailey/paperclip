# PR #6541: fix(adapter-utils): prevent EPIPE crash when writing to child stdin
**URL:** [https://github.com/paperclipai/paperclip/pull/6541](https://github.com/paperclipai/paperclip/pull/6541)

## Thinking Path

> - Paperclip orchestrates AI agents for zero-human companies
> - The CLI and Server subsystems heavily rely on spawning child processes (via `runChildProcess` in `adapter-utils`) to execute fast, external tasks like Git operations during imports and exports.
> - An issue exists where if a child process terminates instantly—or closes its standard input pipe before the server finishes streaming `opts.stdin` to it—Node.js emits an asynchronous `EPIPE` error on the `stdin` stream.
> - Because `runChildProcess` lacked an `error` listener on the child's `stdin`, this `EPIPE` bubbles up as an `uncaughtException`, taking down the entire Paperclip server.
> - This pull request adds a graceful `error` listener to the child's `stdin` to swallow expected `EPIPE` and `EOF` errors.
> - The benefit is improved server stability, completely eliminating intermittent `ECONNRESET` and server crashes during operations that pipe data into fast-executing child processes (such as `company import`).

## What Changed

- Added an `.on("error")` handler to `child.stdin` in `runChildProcess` (`packages/adapter-utils/src/server-utils.ts`) that gracefully ignores `EPIPE` and `EOF` errors if the child exits while we are writing to it.

## Verification

- Run `pnpm vitest run cli/src/__tests__/company-import-export-e2e.test.ts`. Before this change, the test would deterministically crash the server and fail with `TypeError: fetch failed / ECONNRESET`. After this change, it succeeds reliably.

## Risks

- Low risk. Catching and swallowing `EPIPE` errors on process `stdin` streams is the standard, documented best practice in Node.js. It does not mask other actual spawn or execution errors.

## Model Used

- Provider and model name: Gemini 3.1 Pro (High)
- Exact model ID or version: gemini-3.1-pro
- Reasoning/thinking mode: Standard thinking
- Capabilities: Executed commands locally, read logs, and monkeypatched Node.js `Socket.prototype.write` to trace the asynchronous error.

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
