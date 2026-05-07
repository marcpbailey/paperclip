# Feature: Dynamic Model Selection for `openrouter-local`

## Objective

Replace the static 7-model list in `openrouter-local` with a live fetch from the
OpenRouter `/models` endpoint, and add `detectModel` support so agents can pick
up a model from the environment without explicit config.

## Motivation

The current static model list in [`packages/adapters/openrouter-local/src/index.ts`](../../packages/adapters/openrouter-local/src/index.ts)
must be maintained by hand and is always stale. OpenRouter exposes hundreds of
models, including a free tier, reasoning models, and vision models. The
`ServerAdapterModule` interface already supports `listModels` and `detectModel`
hooks — we just need to implement them.

## Scope

Two new exports wired into `createServerAdapter()`:

| Export | Interface hook | Purpose |
|---|---|---|
| `listModels()` | `ServerAdapterModule.listModels` | Fetch live model list from OpenRouter |
| `detectModel()` | `ServerAdapterModule.detectModel` | Read model from `OPENROUTER_MODEL` env var |

The static `models` array in `src/index.ts` is retained as the UI fallback for
non-OpenRouter endpoints.

---

## `listModels`

### Endpoint

```
GET https://openrouter.ai/api/v1/models
Authorization: Bearer <OPENROUTER_API_KEY>
```

No pagination — the endpoint returns all models in a single response.

### Scoping to OpenRouter

`listModels()` takes no arguments, so it cannot see per-agent `baseUrl` config.
The function must decide at the process level whether it can reach OpenRouter:

- **OpenRouter path**: `OPENROUTER_API_KEY` is set → fetch from
  `https://openrouter.ai/api/v1/models` → apply filters → return list.
- **Fallback path**: `OPENROUTER_API_KEY` is not set → return a single sentinel
  entry:
  ```ts
  { id: "", label: "Non-OpenRouter endpoint — enter model name manually" }
  ```
  This tells the UI that the model field is free-text only.

Limitation: an agent with a custom `baseUrl` but with `OPENROUTER_API_KEY` set
will receive the OpenRouter model list in the UI. This is an acceptable
inaccuracy; it degrades gracefully (agent config `model` overrides whatever the
UI selected).

### Filtering

Apply **both** filters. A model must pass both to be included:

1. **Tool use** — `supported_parameters` includes `"tools"`. This is the hard
   requirement; models without it cannot participate in the tool-calling loop.

2. **Not expired** — `expiration_date`, if present, is in the future (or absent).
   Expired models remain callable on OpenRouter but appear as unavailable in some
   UIs; exclude them to avoid confusing entries.

**Do not filter on**:
- Free vs paid — include both; free models are surfaced via the label (see below).
- Reasoning / thinking — include; surfaced via the label.
- Modality — include multimodal models; the tool loop works fine with them and
  excluding vision models would be harmful for users who want them.
- `is_moderated` — neutral; do not filter.

### Response shape (relevant fields only)

```ts
interface OpenRouterModel {
  id: string;                        // e.g. "anthropic/claude-sonnet-4"
  name: string;                      // e.g. "Anthropic: Claude Sonnet 4"
  pricing: {
    prompt: string;                  // cost per token as decimal string; "0" = free
    completion: string;
  };
  supported_parameters: string[];    // see known values below
  architecture: {
    input_modalities: string[];      // e.g. ["text", "image"]
  };
  expiration_date?: string | null;   // ISO date string or absent
}
```

Known `supported_parameters` values (as of 2026-05):

```
frequency_penalty, include_reasoning, logit_bias, logprobs, max_completion_tokens,
max_tokens, min_p, parallel_tool_calls, presence_penalty, reasoning,
reasoning_effort, repetition_penalty, response_format, seed, stop,
structured_outputs, temperature, tool_choice, tools, top_k, top_logprobs,
top_p, verbosity
```

### Label composition

`AdapterModel.label` is composed from three parts:

```
{name}  [{tags}]
```

**Tags** are derived from the model's properties. Include a tag for each of the
following that applies, in this order:

| Tag | Condition |
|---|---|
| `free` | `pricing.prompt === "0"` AND `pricing.completion === "0"` |
| `thinking` | `supported_parameters` includes `"reasoning"` OR `"include_reasoning"` |
| `vision` | `architecture.input_modalities` includes `"image"` |
| `structured` | `supported_parameters` includes `"structured_outputs"` |
| `parallel-tools` | `supported_parameters` includes `"parallel_tool_calls"` |

Tags are appended in brackets, comma-separated. Examples:

```
Anthropic: Claude Sonnet 4
Meta: Llama 4 Scout [free]
DeepSeek: R1 [free, thinking]
Google: Gemini 2.0 Flash [vision, structured, parallel-tools]
Baidu: CoBuddy [free, thinking]
```

If no tags apply, omit the brackets entirely.

### Sorting

Return models sorted by:
1. Free models first (pricing.prompt === "0")
2. Then alphabetically by `name` within each tier

### Caching

Cache the fetched list in module-level memory for **5 minutes**. This avoids a
network call on every UI render while keeping the list reasonably fresh.
Invalidate the cache when `refreshModels()` is called (see below).

### `refreshModels`

Implement `ServerAdapterModule.refreshModels` as an alias for `listModels` that
also clears the cache before fetching.

### Error handling

If the fetch fails (network error, non-2xx, malformed JSON), log a warning and
return the static `models` array from `src/index.ts` as a safe fallback. Do not
throw.

---

## `detectModel` and model resolution order

```ts
detectModel(): Promise<{
  model: string;
  provider: string;
  source: string;
  candidates?: string[];
} | null>
```

Read `process.env.OPENROUTER_MODEL`. If set and non-empty, return:

```ts
{
  model: process.env.OPENROUTER_MODEL,
  provider: "openrouter",
  source: "env_OPENROUTER_MODEL",
}
```

If unset or empty, return `null` (no detection; fall back to agent config or
UI selection).

### Model resolution order in `execute`

The adapter already resolves the model via a priority chain. `OPENROUTER_MODEL`
is inserted as a new middle tier:

| Priority | Source | Already exists? |
|---|---|---|
| 1 | `config.model` (explicit agent config) | ✓ |
| 2 | `OPENROUTER_MODEL` env var | **new** |
| 3 | `DEFAULT_OPENROUTER_LOCAL_MODEL` (`anthropic/claude-sonnet-4`) | ✓ |

Implementation in `execute.ts`:

```ts
const model = asString(
  config.model,
  process.env.OPENROUTER_MODEL?.trim() || DEFAULT_OPENROUTER_LOCAL_MODEL,
);
```

---

## Implementation location

All new logic lives in a new file:

```
packages/adapters/openrouter-local/src/server/models.ts
```

Exports: `listModels`, `refreshModels`, `detectModel`, and the internal
`buildModelLabel` (exported for unit testing).

Wire into `createServerAdapter()` in `src/server/index.ts`:

```ts
import { listModels, refreshModels, detectModel } from "./models.js";

export function createServerAdapter(): ServerAdapterModule {
  return {
    // ... existing fields ...
    listModels,
    refreshModels,
    detectModel,
  } as ServerAdapterModule & { label: string };
}
```

---

## Tests

In `src/server/models.test.ts`:

1. `buildModelLabel` — unit tests for tag composition:
   - free model → `[free]` tag
   - reasoning model → `[thinking]` tag
   - both → `[free, thinking]`
   - no matching params → no brackets
2. `listModels` filtering — mock the fetch; verify:
   - models without `"tools"` are excluded
   - expired models are excluded
   - non-expired models with `"tools"` are included
3. `listModels` fallback — mock fetch to throw; verify static model list returned
4. `listModels` caching — two calls with a mocked fetch; verify fetch called once
5. `detectModel` — env var set → returns correct shape; unset → returns null

---

## Done when

1. `listModels` returns a live, filtered, tagged model list when `OPENROUTER_API_KEY`
   is set; returns the sentinel fallback entry when it is not.
2. `detectModel` reads `OPENROUTER_MODEL` correctly.
3. Both are wired into `createServerAdapter()`.
4. All tests pass (`vitest run`).
5. The static `models` array in `src/index.ts` is retained unchanged as the
   offline fallback.
