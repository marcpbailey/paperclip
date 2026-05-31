#!/usr/bin/env bash
#
# Prepends an @/paperclip/AGENTS.md include to each agent's AGENTS.md so that
# company-wide context is loaded regardless of which issue triggered the run.
#
# Run inside the paperclip container:
#   docker exec paperclip-linkcast-server-1 bash /app/local/bin/prepend-agents-include.sh
#
set -euo pipefail

AGENTS_ROOT="/paperclip/companies/linkcast/agents"
INCLUDE_LINE="@/paperclip/AGENTS.md"

for agents_md in "$AGENTS_ROOT"/*/AGENTS.md; do
  agent_dir=$(dirname "$agents_md")
  name=$(basename "$agent_dir")

  # Skip if already present
  if grep -qF "$INCLUDE_LINE" "$agents_md"; then
    echo "OK     $name: include already present"
    continue
  fi

  # Prepend: write include + blank line + existing content
  tmp=$(mktemp)
  { printf '%s\n\n' "$INCLUDE_LINE"; cat "$agents_md"; } > "$tmp"
  mv "$tmp" "$agents_md"
  echo "UPDATED $name: prepended $INCLUDE_LINE"
done
