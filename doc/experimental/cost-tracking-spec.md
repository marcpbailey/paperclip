# Feature: USD Cost Tracking for `openrouter-local`

## Objective

Populate the `costUsd` field in run results with actual USD cost fetched from
the OpenRouter `/generation` endpoint, replacing the hardcoded `0` currently
emitted.

## Motivation

OpenRouter calculates per-request billing with sub-cent precision. Surfacing
this in the Paperclip run transcript and result gives operators visibility into
actual spend per agent run — useful for budgeting, model comparison, and
identifying runaway agents.

This is a small delta on an already-working adapter: the cost field exists in
the result shape, the API key is already in scope, and the endpoint is simple.

---

## OpenRouter generation endpoint

```
GET https://openrouter.ai/api/v1/generation?id={generation_id}
Authorization: Bearer <OPENROUTER_API_KEY>
```

### Response (relevant fields)

```ts
interface GenerationResponse {
  data: {
    id: string;
    model: string;
    total_cost: number;        // USD — see currency note below
    usage: number;             // USD (same as total_cost in most cases)
    tokens_prompt: number;     // native prompt token count from provider
    tokens_completion: number; // native completion token count from provider
    provider_name: string;     // actual serving provider, e.g. "Anthropic"
    latency: number;           // ms
    finish_reason: string;
  };
}
```

**Currency:** `total_cost` is denominated in USD per the OpenRouter API
reference. The response carries no currency field — the denomination is
implicit in the API contract, not runtime-detectable. There is no need to look
for a currency discriminator in the response; USD is the only denomination
OpenRouter uses.

`total_cost` is the authoritative cost figure. `provider_name` is more reliable
than the `provider` field on the completion object, which not all models
populate.

---

## Scope

Cost fetching is **OpenRouter-only**. The `isOpenRouter(baseUrl)` guard already
exists in `execute.ts` and is reused here. For non-OpenRouter endpoints the
behaviour is unchanged: `costUsd` remains `0`.

---

## Implementation

### 1. Collect generation IDs during the tool loop

Each completion response has an `id` field. Accumulate into `RunState`:

```ts
interface RunState {
  // ... existing fields ...
  generationIds: string[];   // new
}

// initialise:
const state: RunState = {
  // ...
  generationIds: [],
};

// inside the loop, after each completion:
if (completion.id) {
  state.generationIds.push(completion.id);
}
```

### 2. Fetch costs after the loop

After the tool loop exits (success or iteration cap), fetch all generation
records in parallel. Best-effort: individual fetch failures are logged and
contribute `0` to the total.

```ts
async function fetchGenerationCost(
  id: string,
  apiKey: string,
): Promise<{ costUsd: number; providerName: string | null }> {
  try {
    const url = `https://openrouter.ai/api/v1/generation?id=${encodeURIComponent(id)}`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
    });
    if (!res.ok) return { costUsd: 0, providerName: null };
    const json = await res.json() as { data?: GenerationResponse["data"] };
    return {
      costUsd: json.data?.total_cost ?? 0,
      providerName: json.data?.provider_name ?? null,
    };
  } catch {
    return { costUsd: 0, providerName: null };
  }
}
```

### 3. Timing delay

OpenRouter's billing pipeline has a small lag — the generation record may not
exist immediately after the completion returns. Wait **800ms** before fetching,
applied once before the parallel fetch block. This is only incurred when
`isOpenRouter(baseUrl)` is true and at least one generation ID was collected.

```ts
if (isOpenRouter(baseUrl) && state.generationIds.length > 0) {
  await new Promise((resolve) => setTimeout(resolve, 800));
  const results = await Promise.all(
    state.generationIds.map((id) => fetchGenerationCost(id, apiKey)),
  );
  state.costUsd = results.reduce((sum, r) => sum + r.costUsd, 0);
  // Use provider_name from the last generation as the authoritative provider.
  const lastProvider = results.at(-1)?.providerName ?? null;
  if (lastProvider) state.provider = lastProvider;
}
```

### 4. Wire into result emission

`costUsd` is already emitted in the `kind: "result"` event and returned in
`AdapterExecutionResult`. Replace the hardcoded `0`:

```ts
// kind: "result" emit:
costUsd: state.costUsd,

// AdapterExecutionResult return:
// (no change needed — costUsd is not currently in our return shape;
//  add it if AdapterExecutionResult supports it, otherwise the transcript
//  entry is the primary surface)
```

Update `RunState` initialisation:

```ts
const state: RunState = {
  inputTokens: 0,
  outputTokens: 0,
  cachedInputTokens: 0,
  provider: null,
  model,
  finalAssistantText: "",
  generationIds: [],   // new
  costUsd: 0,          // new
};
```

---

## `provider_name` improvement

The generation endpoint's `provider_name` is more reliable than the `provider`
field on the completion object (which many models omit). By using the last
generation's `provider_name` as `state.provider`, we get a correct provider
label even for models that don't populate it in the completion response.

---

## Error handling

| Scenario | Behaviour |
|---|---|
| Non-OpenRouter `baseUrl` | Skip entirely; `costUsd` stays `0` |
| `apiKey` absent | Skip entirely (already handled — adapter aborts earlier) |
| Fetch network error | Log to stderr, contribute `0` to total |
| Non-2xx response | Contribute `0` to total, no log |
| `total_cost` missing from response | Contribute `0` to total |
| All fetches fail | `costUsd: 0`, run completes normally |

---

## Implementation location

All changes in `src/server/execute.ts` only:

1. `fetchGenerationCost()` helper function (module-level, unexported).
2. `generationIds` and `costUsd` added to `RunState`.
3. `completion.id` pushed to `state.generationIds` inside the loop.
4. Post-loop fetch block (timing delay + parallel fetch + accumulation).
5. `costUsd: state.costUsd` in `kind: "result"` emit.

No new files. No new dependencies (`fetch` is available in the Node runtime
used by the adapter).

---

## Tests

In `src/server/execute.test.ts` (extend existing):

1. **Non-OpenRouter baseUrl** — mock fetch; verify generation endpoint never
   called; `costUsd: 0` in result emit.
2. **OpenRouter, single turn** — mock one completion with `id: "gen-abc"`;
   mock generation endpoint returning `{ data: { total_cost: 0.001, provider_name: "Anthropic" } }`;
   verify `costUsd: 0.001` and `provider: "Anthropic"` in result.
3. **OpenRouter, multi-turn** — mock three completions with distinct IDs; mock
   generation endpoint returning different costs per ID; verify `costUsd` is
   the sum.
4. **Generation fetch fails** — mock generation endpoint to throw; verify
   `costUsd: 0` and run completes without error.
5. **Generation endpoint returns non-2xx** — verify `costUsd: 0`, no throw.
6. **`provider_name` from generation overrides completion `provider` field** —
   verify `state.provider` is set from generation response even when completion
   object had no `provider` field.

---

## Done when

1. `costUsd` in `kind: "result"` reflects actual OpenRouter spend, summed
   across all tool loop iterations.
2. `state.provider` populated from `provider_name` when available.
3. Non-OpenRouter endpoints unaffected.
4. All fetch failures degrade gracefully to `costUsd: 0`.
5. All tests pass.
