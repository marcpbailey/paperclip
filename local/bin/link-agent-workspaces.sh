#!/usr/bin/env bash
#
# Creates symlinks from each agent's fallback workspace UUID directory to their
# company workspace at /paperclip/companies/linkcast/agents/<name>.
#
# This is the workaround for Paperclip issue #1425 (no per-agent workspace path).
# Without it, agents with no project on their issue land in the UUID fallback dir
# and miss /paperclip/AGENTS.md and company-level context files.
#
# Run inside the paperclip container:
#   docker exec paperclip-linkcast-server-1 bash /app/local/bin/link-agent-workspaces.sh
#
set -euo pipefail

WORKSPACES_ROOT="/paperclip/instances/default/workspaces"
AGENTS_ROOT="/paperclip/companies/linkcast/agents"

declare -A AGENTS=(
  ["fury"]="ab6cd931-e986-486c-bc9a-73d02b970576"
  ["stark"]="fc4e3ebb-6d5a-4b5e-a089-f31e1da228d8"
  ["natasha"]="1652248b-2eef-41bc-9e70-7e2e14a00afc"
  ["nebula"]="d6a17c58-0654-4e7b-bc0b-4726df738a59"
  ["thor"]="56f887df-07cf-415b-b833-94306bff5eaf"
  ["clint"]="702689b3-5b29-4411-b586-79138dc6edd8"
  ["loki"]="ee2bd95b-84dd-43c8-89f5-7c909c62a8a0"
  ["banner"]="6a185af9-4327-429a-a7a9-42df3973cdf6"
  ["starlord"]="396e3faa-0e3d-4b2e-947c-4abf3fe9a424"
  ["drax"]="ed2b9f4d-b0ef-4c64-97b8-6d74a020bea4"
  ["gamora"]="eab55780-04d9-4919-ab4e-11847ff029f4"
)

mkdir -p "$WORKSPACES_ROOT"

for name in "${!AGENTS[@]}"; do
  uuid="${AGENTS[$name]}"
  link="$WORKSPACES_ROOT/$uuid"
  target="$AGENTS_ROOT/$name"

  if [[ ! -d "$target" ]]; then
    echo "SKIP   $name: target $target does not exist"
    continue
  fi

  if [[ -L "$link" ]]; then
    existing=$(readlink "$link")
    if [[ "$existing" == "$target" ]]; then
      echo "OK     $name: already linked → $target"
      continue
    fi
    echo "RELINK $name: $link → $target (was → $existing)"
    rm "$link"
  elif [[ -d "$link" ]]; then
    echo "BACKUP $name: $link → ${link}.bak"
    mv "$link" "${link}.bak"
  fi

  ln -s "$target" "$link"
  echo "LINKED $name: $link → $target"
done
