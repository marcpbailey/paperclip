# _AGENTS

Local overrides and security requirements for the LinkCast environment.

## Source Discipline

This repo follows the **Integration Manager Workflow** (see [Pro Git §5.1][pro-git]) with
**downstream patching** for pending PRs.

[pro-git]: https://git-scm.com/book/en/v2/Distributed-Git-Distributed-Workflows

### Remotes

| Remote | Repo | Role |
|--------|------|------|
| `origin` | `paperclipai/paperclip` | Upstream master — no push access |
| `fork` | `marcpbailey/paperclip` | PR staging fork — push feature branches here |
| `paperclip` | `LinkCast/paperclip` | Remote backup of local `main` |

Local branch `main` is the running deployment. It tracks upstream via periodic merges from
`origin` and includes downstream patches (cherry-picks) from pending fork PR branches.

### File ownership

**Upstream-owned** — any file present on `origin/master`:
```sh
git log --oneline origin/master -- <path>   # returns commits → upstream-owned
```

**Local-only** — changes that will never be PRed upstream. Confined to `local/` unless
an explicit exception is agreed. Examples: `local/skills/`, `local/compose/`, `local/bin/`,
`local/doc/`, this file.

### Routine upstream sync

Use the `update` make target, which fetches the latest upstream release branches, prompts for
selection, and pushes to both remotes:

```sh
pcc make update                  # interactive: shows recent release tags, 0 to abort
pcc make update VERSION=v2026.529.0  # non-interactive: merge a specific tag
```

`fork` is a PR staging area, not a sync relay — there is no need to route through it. If a
pending cherry-pick on `main` was merged upstream in the same sync, Git's patch-id detection
will skip it cleanly.

### Workflow for upstream-owned files (Integration Manager path)

1. Sync fork: `git fetch origin && git push fork main`
2. Branch from upstream — **not from `main`**: `git checkout -b feat/<slug> origin/master && git push fork feat/<slug>`
   Branching from `main` instead of `origin/master` contaminates the branch history with
   local-only commits (e.g. skills-catalog, downstream patches) that have no business in
   an upstream PR.
3. Commit changes on the branch, push to `fork`.
4. Open PR: `marcpbailey/paperclip:feat/<slug>` → `paperclipai/paperclip:master`
   _(Marc runs this manually — `gh` is 1Password-shimmed, agents cannot call it)_
5. Downstream patch: `git checkout main && git cherry-pick <sha>`
6. Test, then backup: `git push paperclip main`

**Never edit an upstream-owned file on `main` without a fork branch already existing.**

### Workflow for local-only files

Commit directly to `main`, push to `paperclip` remote. No fork branch, no PR.

```sh
git add local/<path>
git commit -m "<message>"
git push paperclip main
```

### Decision tree

```
Is the file on origin/master?
  YES  → Integration Manager path (fork branch + cherry-pick). Never edit on main first.
  NO   → Is the file under local/ or confirmed local-only?
           YES → Commit directly to main, push to paperclip remote.
           NO  → Stop. Clarify with Marc before proceeding.
```

### Hard rules

- Never push to `origin` (no push access; will fail or create conflicts).
- Never edit upstream-owned files on `main` without a corresponding fork branch.
- Never run `gh` CLI from an agent — write the command for Marc to run instead.
- Always push to `paperclip` remote after local-only changes are tested.

---

## Orchestration & API Tooling

**Never run raw `docker compose` or `docker` commands directly.** Always go through the wrapper
scripts. They handle 1Password secret resolution, enforce the correct compose file layering, and
prevent API keys from leaking into the process list.

### `pcc` — paperclip-control.sh

`pcc` (alias for `./local/bin/paperclip-control.sh`) is the single entry point for all stack
and build operations. Run `pcc help` for the full reference. Key subcommands:

| Command | Effect |
|---------|--------|
| `pcc start` | Bring the stack up (resolves 1Password secrets) |
| `pcc stop` | Stop containers, keep volumes |
| `pcc restart` | stop + start |
| `pcc teardown` | `docker compose down` (containers removed, volumes kept) |
| `pcc status` | `docker compose ps` |
| `pcc logs [service]` | Tail logs |
| `pcc version` | Repo tag/sha, image build date, adapter sync status |
| `pcc env` | Print env diagnostics without exposing secret values |
| `pcc test` | Fast unit/integration suite |
| `pcc fulltest` | Full pre-hand-off suite (typecheck + tests + build) |
| `pcc make <target>` | Pass-through to `local/Makefile` with secrets established |

Use `pcc make <target>` for any Makefile target that subsequently calls `pcc restart` (e.g.
`deploy-adapter`, `deploy-container`). Use `pcc make update` to sync with upstream.

| Command | Effect |
|---------|--------|
| `pcc make update` | Sync local main with an upstream release (interactive, or `VERSION=vX.Y.Z`) |
| `pcc make deploy-adapter` | Compile adapter, sync to overlay, and restart |
| `pcc make deploy-container` | Rebuild server image and restart |
| `pcc make all` | Full rebuild (container + adapter), sync, restart, and fast test |
| `pcc make build-container` | Rebuild the server Docker image (no cache for app source layers) |
| `pcc make build-adapter` | Compile the openrouter-agent adapter |
| `pcc make sync-adapter` | Sync compiled adapter to the linkcast crew overlay |
| `pcc make restart` | Restart the Paperclip stack |
| `pcc make test` | Fast unit/integration test suite |
| `pcc make fulltest` | Full pre-hand-off suite (typecheck + tests + build) |

### `pca` — paperclip-api.sh

`pca` (alias for `./local/bin/paperclip-api.sh`) wraps all `curl`-based API calls. It resolves
1Password secrets and writes temporary config files so API keys never appear in `ps` output.

### Security rationale

See `local/doc/experimental/2026-05-04-paperclip-control-security-critique.md` for the full
rationale behind this approach.
