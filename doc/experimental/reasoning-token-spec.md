# Feature: Reasoning Token Support for `openrouter-local`

## Objective

Detect, extract, and emit reasoning/thinking content from model responses as
`kind: "thinking"` transcript entries, making chain-of-thought visible in the
Paperclip run viewer for models that support it.

## Motivation

With dynamic model listing (see `feature-dynamicmodels-spec.md`), reasoning
models such as DeepSeek R1, QwQ, and Claude with extended thinking are exposed
in the model picker. When a user selects one of these models, the response
contains thinking tokens that the adapter currently discards silently. The run
transcript shows only the final assistant text, giving no visibility into the
reasoning chain.

This is low implementation risk — response-side extraction requires no request
changes and degrades gracefully (no-op for models that don't emit reasoning).

---

## OpenRouter reasoning response formats

OpenRouter normalises reasoning content from different providers into two
locations on `choices[0].message`:

### 1. `message.reasoning` (string)
A plain string containing the full thinking trace. Present for DeepSeek R1,
QwQ, and models routed via the `:thinking` model variant suffix.

```ts
// Example shape (beyond OpenAI SDK types — cast required)
interface MessageWithReasoning {
  reasoning?: string;
  reasoning_details?: ReasoningDetail[];
}
```

### 2. `message.reasoning_details` (array)
An array of typed objects. Each object has a `type` field:

| type | meaning |
|---|---|
| `reasoning.text` | Plain text reasoning chunk |
| `reasoning.summary` | Condensed summary of the thinking trace |
| `reasoning.encrypted` | Opaque encrypted trace (for cross-turn preservation) |

For transcript purposes, extract only `reasoning.text` and `reasoning.summary`
entries; ignore `reasoning.encrypted` (not human-readable).

### Priority

If both `message.reasoning` (string) and `message.reasoning_details` (array)
are present, prefer `reasoning_details` — it is more structured. Fall back to
`message.reasoning` if `reasoning_details` is absent or empty of readable
entries.

---

## Request-side: enabling reasoning

Some models emit reasoning content unconditionally; others require an explicit
request parameter. OpenRouter supports two formats:

### Unified `reasoning` parameter (preferred)
```ts
{
  reasoning: { effort: "high" }      // effort: xhigh | high | medium | low | minimal | none
  // or:
  reasoning: { max_tokens: 8000 }    // direct token budget
  // or:
  reasoning: { enabled: true }       // enable with model defaults
}
```
Supported by: OpenAI o-series, Anthropic Claude 3.7+, Gemini reasoning models,
Qwen3.5+, xAI, and others. Corresponds to `"reasoning"` in
`supported_parameters`.

### Legacy `include_reasoning` parameter
```ts
{
  include_reasoning: true
}
```
Supported by older DeepSeek models. Corresponds to `"include_reasoning"` in
`supported_parameters`.

### Model variant suffix
Appending `:thinking` to the model ID (e.g. `deepseek/deepseek-r1:thinking`)
enables reasoning mode on OpenRouter's side without an explicit request
parameter.

---

## Adapter behaviour

### Response extraction (always active)

Regardless of how the model was invoked, always attempt to extract reasoning
content from each completion response. This means:

- Models that emit reasoning unconditionally are handled with no config.
- Models that require a request parameter get full support when that parameter
  is sent (see below).
- Models with no reasoning support produce nothing — no-op, zero cost.

Extraction logic (pseudocode):

```ts
function extractReasoningText(message: unknown): string | null {
  const msg = message as Record<string, unknown>;

  // Prefer structured details
  const details = msg.reasoning_details;
  if (Array.isArray(details) && details.length > 0) {
    const readable = details
      .filter((d): d is Record<string, unknown> =>
        typeof d === "object" && d !== null &&
        (d.type === "reasoning.text" || d.type === "reasoning.summary")
      )
      .map((d) => String(d.text ?? d.content ?? ""))
      .filter(Boolean);
    if (readable.length > 0) return readable.join("\n\n");
  }

  // Fall back to plain string
  const reasoning = msg.reasoning;
  if (typeof reasoning === "string" && reasoning.trim().length > 0) {
    return reasoning;
  }

  return null;
}
```

### Request parameter injection (opt-in)

Add an optional `reasoning` config field to the adapter:

```ts
// In agentConfigurationDoc:
// - reasoning (object | boolean, optional): passed as the `reasoning` request
//   parameter for models that support it. Examples:
//     reasoning: { effort: "high" }
//     reasoning: { max_tokens: 8000 }
//     reasoning: true   (shorthand for { enabled: true })
//   Has no effect on models that ignore it. Do not set for models that use
//   the :thinking variant suffix — those enable reasoning via the model ID.
```

In `execute.ts`, include in the completions call when set:

```ts
const reasoningParam = resolveReasoningParam(config.reasoning);

const completion = await client.chat.completions.create({
  model,
  messages,
  tools: ...,
  tool_choice: ...,
  ...(reasoningParam ? { reasoning: reasoningParam } : {}),
});
```

```ts
function resolveReasoningParam(value: unknown): Record<string, unknown> | null {
  if (!value) return null;
  if (value === true) return { enabled: true };
  if (typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return null;
}
```

`include_reasoning` is handled automatically: if the model ID is known via
dynamic listing to support only `include_reasoning` (not the unified
`reasoning` parameter), inject `include_reasoning: true` instead. Without
dynamic listing, operators targeting legacy DeepSeek models can pass
`extraHeaders` or rely on the `:thinking` variant suffix.

---

## Transcript emission

Emit a `kind: "thinking"` entry immediately before the `kind: "assistant"`
entry it precedes, whenever reasoning content is present:

```ts
if (reasoningText) {
  await emit({
    kind: "thinking",
    ts: new Date().toISOString(),
    text: reasoningText,
  });
}
if (message.content) {
  await emit({
    kind: "assistant",
    ts: new Date().toISOString(),
    text: message.content,
  });
}
```

The `kind: "thinking"` shape matches talha's `emitThinking` and claude-local's
extended thinking transcript format for consistency across adapters.

---

## Token accounting

Reasoning tokens are billed as output tokens by OpenRouter. The adapter
already accumulates `completion_tokens` from `usage.completion_tokens` — no
change required to the billing path.

If the platform later exposes a `thinkingTokens` field in `UsageSummary`, wire
it from `usage.completion_tokens_details?.reasoning_tokens` (OpenAI format,
forwarded by some OpenRouter providers):

```ts
const thinkingTokens =
  (usage as unknown as {
    completion_tokens_details?: { reasoning_tokens?: number };
  }).completion_tokens_details?.reasoning_tokens ?? 0;
```

This is best-effort — absent when the upstream provider doesn't report it.

---

## Dynamic model listing integration

The `[thinking]` tag in the dynamic model list (from `feature-dynamicmodels-spec.md`)
already identifies models where `supported_parameters` includes `"reasoning"`
or `"include_reasoning"`. A future enhancement can use this to auto-inject the
appropriate request parameter when a tagged model is selected, removing the
need for manual `reasoning` config. This is deferred until `listModels` is
implemented.

---

## Implementation location

Changes are confined to `execute.ts`:

1. `extractReasoningText(message)` helper function.
2. `resolveReasoningParam(value)` helper function.
3. In the completion loop: extract reasoning, emit `kind: "thinking"` if
   present, then emit `kind: "assistant"` as today.
4. Pass `reasoning` param in completions call when `config.reasoning` is set.

No new files required.

---

## Tests

In `src/server/execute.test.ts` (extend existing):

1. **No reasoning in response** — response has no `reasoning` or
   `reasoning_details`; verify no `kind: "thinking"` entry emitted.
2. **`message.reasoning` string** — response has `reasoning: "let me think..."`;
   verify `kind: "thinking"` emitted before `kind: "assistant"`.
3. **`message.reasoning_details` array** — response has readable
   `reasoning.text` and `reasoning.encrypted` entries; verify only the text
   entries are emitted, encrypted is ignored.
4. **Both present** — `reasoning_details` takes precedence over `message.reasoning`.
5. **`config.reasoning: true`** — verify `{ enabled: true }` passed in
   completions call.
6. **`config.reasoning: { effort: "high" }`** — verify forwarded verbatim.
7. **`config.reasoning` absent** — verify no `reasoning` key in completions
   call.

---

## Done when

1. Reasoning content from `message.reasoning` (string) is extracted and emitted
   as `kind: "thinking"` in the transcript.
2. Reasoning content from `message.reasoning_details` is extracted, with
   encrypted entries ignored.
3. `config.reasoning` is forwarded to the completions API when set.
4. No `kind: "thinking"` entries appear for models that return no reasoning
   content.
5. All tests pass.
6. `reasoning` config option documented in `agentConfigurationDoc`.
