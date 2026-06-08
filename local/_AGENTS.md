# _AGENTS

Local overrides and security requirements for the LinkCast environment.


## Agent Behavioral Rules

**1. No Autonomous Speculative Coding**
If the user asks a speculative question or asks for options (e.g., "what is a good approach?", "how would we fix this?"), you MUST ONLY answer the question or propose the options. Do NOT assume you should proceed with implementing the answer. Discuss the design and wait for the user to explicitly confirm the approach (e.g., "make it so", "go ahead") before making any code changes.

**2. No Raw Docker Compose / Container Commands**
NEVER run `docker compose` or raw container lifecycle commands directly. All container operations (build, deploy, start, stop, restart, teardown, status) MUST be managed exclusively through `local/bin/paperclip-control.sh` (often aliased as `pcc`). This script safely handles environment variable stubs and secret injection that raw Docker Compose commands will fail on or corrupt.

**3. Explicit Permission for Container Changes**
Agents MUST NOT execute `paperclip-control.sh` (or `make` targets that invoke it) autonomously. You must ALWAYS ask the user for explicit permission and wait for their approval before running any script that alters the container lifecycle.

## Source Discipline

This repo follows the **Integration Manager Workflow** (see [Pro Git §5.1][pro-git]) with
**downstream patching** for pending PRs.

[pro-git]: https://git-scm.com/book/en/v2/Distributed-Git-Distributed-Workflows

### Remotes

| Remote | Repo | Role |
|--------|------|------|
| `origin` | `paperclipai/paperclip` | Upstream master — no push access |
| `fork` | `marcpbailey/paperclip` | PR staging fork — push feature branches here |
| `paperclip` | `LinkCast/paperclip` | Primary repo and remote backup of local `main` |

Local ~/Projects/paperclip/ branch `main` is the running deployment. It tracks upstream via periodic merges from
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

### Git workflow flow for changes

```
working copy   (local working copy)
    → branch + PR → linkcast/paperclip        (company fork, reviewed by operator)
    → merge
    → git fetch paperclip && git merge paperclip/main  →  ~/Projects/paperclip
```

For upstream platform updates (`paperclipai/paperclip` → `linkcast/paperclip`), a scheduled Paperclip routine (LINAA-1017) syncs new releases automatically and opens a PR for operator review.

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
           NO  → Stop. Clarify with user before proceeding.
```

### Hard rules

- Never push to `origin` (no push access; will fail or create conflicts).
- Never edit upstream-owned files on `main` without a corresponding fork branch.
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
