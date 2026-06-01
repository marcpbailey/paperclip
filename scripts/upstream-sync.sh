#!/usr/bin/env bash
#
# upstream-sync.sh
#
# Idempotent sync of upstream releases (paperclipai/paperclip) into the
# LinkCast fork (LinkCast/paperclip). Designed to be run from the workspace
# root (/paperclip/workspaces/paperclipai/paperclip) by a daily routine.
#
# Behaviour:
#   1. Ensure the `upstream` remote points at paperclipai/paperclip; fetch tags.
#   2. Resolve the latest upstream *release* tag via GitHub's Latest flag
#      (`gh release view`). Tags are date-versioned (vYYYY.MMDD.0), so we never
#      string-sort them.
#   3. If the release commit is already an ancestor of origin/main => in sync,
#      exit 0 with no PR.
#   4. Otherwise create branch upstream-sync/<tag> off origin/main and merge the
#      release tag:
#        - clean merge  => push branch, open a normal PR into LinkCast/paperclip
#        - conflict     => commit the conflict state, push, open a DRAFT PR and
#                          add a comment listing the conflicted files.
#   5. Idempotent: if the branch or its PR already exist, do not duplicate.
#   6. PRs always target LinkCast/paperclip (base main), never the upstream repo.
#
# Notes on push permission: scripts/check-no-git-push.mjs only scans adapter /
# runtime source roots (packages/adapters, packages/adapter-utils, server/src,
# cli/src). This developer/release script lives in scripts/ and is explicitly
# out of scope, so pushing branches from here is permitted.

set -euo pipefail

UPSTREAM_URL="https://github.com/paperclipai/paperclip.git"
UPSTREAM_REPO="paperclipai/paperclip"
FORK_REPO="LinkCast/paperclip"
BASE_BRANCH="main"

log() { printf '[upstream-sync] %s\n' "$*"; }
die() { printf '[upstream-sync] ERROR: %s\n' "$*" >&2; exit 1; }

# Run from the repo root regardless of caller cwd.
REPO_ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
cd "$REPO_ROOT"

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated"

# 1. Ensure upstream remote + fetch tags.
if git remote get-url upstream >/dev/null 2>&1; then
  current_url="$(git remote get-url upstream)"
  if [ "$current_url" != "$UPSTREAM_URL" ]; then
    log "fixing upstream remote url ($current_url -> $UPSTREAM_URL)"
    git remote set-url upstream "$UPSTREAM_URL"
  fi
else
  log "adding upstream remote -> $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi
log "fetching upstream tags"
git fetch --quiet upstream --tags

# 2. Resolve the latest upstream release tag via the Latest flag.
TAG="$(gh release view -R "$UPSTREAM_REPO" --json tagName -q .tagName)"
[ -n "$TAG" ] || die "could not resolve latest upstream release tag"
log "latest upstream release: $TAG"

TAG_COMMIT="$(git rev-list -n1 "$TAG^{commit}")" \
  || die "tag $TAG not found locally after fetch"
log "release commit: $TAG_COMMIT"

# 3. Fetch origin and check ancestry against origin/main.
log "fetching origin"
git fetch --quiet origin
if git merge-base --is-ancestor "$TAG_COMMIT" "origin/$BASE_BRANCH"; then
  log "in sync: $TAG ($TAG_COMMIT) is already an ancestor of origin/$BASE_BRANCH; no PR needed"
  exit 0
fi

SYNC_BRANCH="upstream-sync/${TAG}"

# 5. Idempotency: existing PR for this head wins.
existing_pr="$(gh pr list -R "$FORK_REPO" --head "$SYNC_BRANCH" \
  --state all --json url -q '.[0].url' 2>/dev/null || true)"
if [ -n "$existing_pr" ]; then
  log "PR already exists for $SYNC_BRANCH: $existing_pr"
  echo "$existing_pr"
  exit 0
fi

# 5. Idempotency: existing remote branch but no PR -> reuse the branch.
remote_branch_exists=false
if git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1; then
  remote_branch_exists=true
  log "remote branch $SYNC_BRANCH already exists; will open a PR for it"
fi

# 4. Build the sync branch off origin/main and merge the release tag.
if [ "$remote_branch_exists" = true ]; then
  git fetch --quiet origin "$SYNC_BRANCH"
  git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
  conflict=false
else
  git checkout -B "$SYNC_BRANCH" "origin/$BASE_BRANCH"
  log "merging $TAG into $SYNC_BRANCH"
  conflict=false
  conflict_files=""
  if git merge --no-edit --no-ff \
       -m "merge: upstream release $TAG into $BASE_BRANCH" "$TAG_COMMIT"; then
    log "clean merge"
  else
    conflict=true
    # Capture conflicted files while the index is still in the unmerged state.
    conflict_files="$(git --no-pager diff --name-only --diff-filter=U 2>/dev/null || true)"
    log "merge produced conflicts; recording conflict state"
    # Stage everything (including files with conflict markers) and commit so
    # the conflict state can be pushed for operator resolution in the PR.
    git add -A
    git commit --no-edit -m "merge (CONFLICTS): upstream release $TAG into $BASE_BRANCH

This merge has unresolved conflicts. Resolve the files listed in the PR
comment, then push to this branch." || true
  fi
fi

# Push the branch.
log "pushing $SYNC_BRANCH to origin"
git push --quiet -u origin "$SYNC_BRANCH"

# Open the PR into the fork (never upstream).
PR_TITLE="upstream sync: $TAG"
if [ "$conflict" = true ]; then
  PR_BODY="Automated upstream sync of release **$TAG** (\`$TAG_COMMIT\`) from \`$UPSTREAM_REPO\` into \`$BASE_BRANCH\`.

:warning: This merge has **unresolved conflicts** and is opened as a draft.
Resolve the conflicted files listed in the comment below, then push to
\`$SYNC_BRANCH\` and mark the PR ready for review."
  log "opening DRAFT PR (conflicts)"
  pr_url="$(gh pr create -R "$FORK_REPO" --base "$BASE_BRANCH" --head "$SYNC_BRANCH" \
    --title "$PR_TITLE (conflicts)" --body "$PR_BODY" --draft)"
  # Conflict comment listing the files.
  if [ -n "$conflict_files" ]; then
    comment="Conflicted files needing operator resolution:

$(printf '%s\n' "$conflict_files" | sed 's/^/- `/; s/$/`/')"
  else
    comment="Merge reported conflicts but no conflicted files could be enumerated; inspect the merge commit manually."
  fi
  gh pr comment -R "$FORK_REPO" "$pr_url" --body "$comment"
else
  PR_BODY="Automated upstream sync of release **$TAG** (\`$TAG_COMMIT\`) from \`$UPSTREAM_REPO\` into \`$BASE_BRANCH\`.

Clean merge — no conflicts. Review and merge to bring LinkCast up to $TAG."
  log "opening PR (clean merge)"
  pr_url="$(gh pr create -R "$FORK_REPO" --base "$BASE_BRANCH" --head "$SYNC_BRANCH" \
    --title "$PR_TITLE" --body "$PR_BODY")"
fi

log "PR ready: $pr_url"
echo "$pr_url"
