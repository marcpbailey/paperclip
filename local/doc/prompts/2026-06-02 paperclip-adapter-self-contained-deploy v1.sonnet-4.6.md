# Paperclip Adapter: Self-Contained Deployment Investigation

## Context

The `paperclip` repo contains a generic OpenRouter adapter at
`packages/adapters/openrouter-agent/`. It is built with `npm run build` and produces
compiled output in `packages/adapters/openrouter-agent/dist/`.

Paperclip's adapter model has two modes:

- Local adapters: hardcoded paths, baked into the paperclip source
- External/uploaded adapters: uploaded at runtime via the UI or API

Neither mode worked cleanly for this adapter out of the box. The current workaround
is to rsync the compiled dist to a sibling repo (`linkcast`, at `../linkcast` relative
to the paperclip repo root) at:

    linkcast/crew/paperclip/companies/linkcast/adapters/paperclip-openrouter-agent/

That path is bind-mounted into the container at:

    /paperclip/companies/linkcast/adapters/

Paperclip discovers the adapter from there.

This creates an unwanted cross-repo dependency. Rebuilding the adapter requires writing
to the `linkcast` repo. The sync is managed by `local/Makefile` targets `build-adapter`,
`sync-adapter`, and `deploy-adapter`, with the destination path in `ADAPTER_DEPLOY`.

The adapter is only rebuilt when paperclip itself changes, so this is not a hot-reload
problem. The goal is to eliminate the cross-repo sync, not to improve iteration speed.

## Goal

Find a deployment method for the adapter that is entirely self-contained within the
`paperclip` repo, with no writes to `linkcast` or any other external repo.

## Requirements

1. The compiled adapter must be discoverable by paperclip at container runtime.
2. Agents inside the container must NOT be able to modify the adapter source. A
   read-only mount is acceptable.
3. Changes to `local/compose/paperclip-boot-linkcast.yaml` and `local/Makefile` are
   in scope.
4. Changes to paperclip upstream source are in scope as a last resort, but must be
   minimal and tracked as a candidate upstream PR.
5. The solution must not require writing to any path outside the `paperclip` repo root
   on the host.

## Approach

Investigate whether a read-only bind-mount of `packages/adapters/openrouter-agent/dist/`
directly into the container can satisfy adapter discovery, without any source changes.

If paperclip's adapter discovery path is hardcoded, identify the minimal source change
needed to make it configurable (via environment variable or compose config), suitable
for an upstream PR.

## Out of scope

- Hot-reload or watch-mode behaviour
- Moving the adapter source out of the `paperclip` repo
- Creating a third repo for the adapter
- Changing how the `linkcast` repo is structured

## Acceptance criteria

- `deploy-adapter` in `local/Makefile` does not write to any path outside the
  `paperclip` repo
- The adapter is loaded correctly by a running paperclip container
- Agents in the container cannot write to the adapter source path

## Open questions

- Does paperclip's adapter discovery support configurable paths today, or is the path
  to `companies/` hardcoded throughout?
- If a bind-mount solution is viable, which container path should the dist be mounted at?
- Are there any upstream PRs already open that touch adapter discovery or loading?

## References

- Adapter source: `packages/adapters/openrouter-agent/`
- Current sync target: `ADAPTER_DEPLOY` in `local/Makefile`
- Compose overlay: `local/compose/paperclip-boot-linkcast.yaml`
- Related Makefile targets: `build-adapter`, `sync-adapter`, `deploy-adapter`
