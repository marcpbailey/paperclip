# OpenRouter-local v2 Analysis

**Date:** 2026-05-07  
**Triggered by:** Discovery of [paperclip-adapter-openrouter](https://github.com/talhamahmood666/paperclip-adapter-openrouter)
by Talha Mahmood — a community-built, npm-published OpenRouter adapter for
Paperclip with 9 stars and 22 commits.

---

## Executive Summary

A side-by-side comparison of `openrouter-local` against the talha community
adapter and the two established first-party adapters (`claude-local`,
`codex-local`) identified five actionable gaps and clarified several apparent
gaps that are either already handled, not worth addressing, or architecturally
incompatible with the in-process design.

Five feature specs were produced as a direct output of this analysis. No
regressions or defects were found in the existing adapter.

---

## Background

### The talha adapter

`paperclip-adapter-openrouter-talha` is a standalone npm package that provides
OpenRouter access for Paperclip agents. Its architecture differs fundamentally
from `openrouter-local`: it spawns an external `openrouter-cli` subprocess and
parses its JSON stdout, rather than running the tool-calling loop in-process.
Its tool set is oriented toward Paperclip control-plane operations (issue
management, delegation, approvals) rather than local workspace manipulation.

### The `openrouter-local` adapter

`openrouter-local` runs an in-process OpenAI-compatible tool-calling loop using
the OpenAI SDK, exposing filesystem and shell tools (`read_file`, `write_file`,
`list_directory`, `run_command`, `apply_patch`) to the model. It is a monorepo
package integrated with `@paperclipai/adapter-utils`.

### Key architectural finding

The adapters are complementary, not competing. The talha adapter is oriented
toward **orchestrating work** (Paperclip API tools); `openrouter-local` is
oriented toward **executing work** (filesystem/shell tools). Agents on
`openrouter-local` reach the Paperclip API today via `run_command` + curl,
which works but has reliability and observability costs at lower model tiers.

---

## In-Process Architecture: Tradeoffs

`openrouter-local` runs its tool-calling loop in-process, unlike `codex-local`
and `claude-local` which spawn CLI subprocesses, and unlike the talha adapter
which spawns `openrouter-cli`. This is a deliberate architectural choice with
significant benefits and some real costs.

### Benefits

**Model agnosticism.** The in-process design is the primary enabler of broad
model support. The Codex CLI is built for OpenAI; the Claude Code CLI is built
for Anthropic. There is no "any OpenRouter model" CLI. Owning the loop is what
makes model freedom a first-class feature.

**Full loop control.** Every feature spec produced by this analysis is feasible
because the adapter owns the loop entirely. Reasoning token extraction
intercepts the completion response directly. Cost tracking collects completion
IDs as they arrive. Native API tools are dispatched in-process. Approval gating
intercepts tool calls before dispatch. With a subprocess model, each of these
would require the CLI to implement and expose the capability.

**Testability.** The `openAiFactory` and `tools` overrides in `ExecuteOptions`
allow the OpenAI client and tool registry to be injected in tests. The full
tool loop can be exercised without any process management — only mock objects
are required. Subprocess adapters must spawn and parse actual CLI output in
integration tests.

**No binary dependency.** The adapter works anywhere the Node.js runtime is
available with a valid API key. No `codex`, `claude`, or `openrouter-cli`
binary is required. Deployment is simpler and Docker images are smaller.

**Latency.** No subprocess spawn overhead per run. No JSONL
serialisation/deserialisation across a pipe boundary. The loop is function
calls and awaited promises.

**Transcript fidelity.** Transcript entries are emitted directly and
precisely. Subprocess adapters parse whatever the CLI emits, which can vary
between CLI versions.

### Downsides

**Not pre-emptable.** Subprocess adapters can send SIGTERM/SIGKILL to a child
process on demand. The in-process model has no equivalent external kill
mechanism. A hung OpenRouter request or misbehaving `run_command` holds the run
until per-tool timeouts fire. There is currently no overall wall-clock timeout
on `execute()`. This is the most significant operational gap and is addressed
by the wall-time-limit spec.

**No process isolation.** An unhandled exception or memory spike in the tool
loop occurs inside the server process, not a sandboxed child. Multiple
concurrent agents share the same event loop and heap. A single agent reading a
very large file or suffering a memory leak affects every other agent on that
instance.

**Shared event loop.** JavaScript is single-threaded. While async/await and
subprocess-based `run_command` avoid most blocking, a slow LLM response
occupies the loop iteration for its duration. At high agent concurrency this
could become a bottleneck.

### Assessment

The in-process model is the correct choice given the primary design goal of
model freedom. The isolation concerns are real but operational — they become
material at a concurrency level not yet reached. The pre-emptability gap is the
one worth actively closing; the wall-time-limit spec addresses it.

---

## Adapter Comparison

| # | Feature | `claude-local` | `codex-local` | `openrouter-local` | `talha` | Coverage |
|---|---|---|---|---|---|---|
| 1 | **Model flexibility** | Anthropic + Bedrock only | OpenAI-primary | Any OpenAI-compatible | Any OpenRouter model | N/A |
| 2 | **Tool loop runs in** | Claude Code CLI | Codex CLI | adapter in-process | `openrouter-cli` subprocess | N/A |
| 3 | **Filesystem tools** | via CLI | via CLI | ✓ in-process | ✗ | N/A |
| 4 | **Paperclip API tools** | via CLI | via CLI | via `run_command` | ✓ 8 typed tools | Feature — [native-api-tools-spec.md](./native-api-tools-spec.md) |
| 5 | **Auto issue state mgmt** | platform-managed | platform-managed | platform-managed | ✓ explicit (in_progress → done/blocked) | No plan |
| 6 | **Issue checkout / pre-lock** | ✗ | ✗ | ✗ | ✓ | Feature — [native-api-tools-spec.md](./native-api-tools-spec.md) |
| 7 | **Final output → issue comment** | via CLI | ✗ | ✗ | ✓ automatic | No plan |
| 8 | **Approval gating (hire_agent)** | ✗ | ✗ | ✗ | ✓ routes through /approvals | Feature — [native-api-tools-spec.md](./native-api-tools-spec.md) |
| 9 | **Runaway loop detection** | via CLI | via CLI | maxIterations cap only | ✓ repeat-call detection | Future |
| 10 | **Reasoning token support** | ✓ (extended thinking) | ✗ | ✗ | ✓ (DeepSeek R1, QwQ) | Feature — [reasoning-token-spec.md](./reasoning-token-spec.md) |
| 11 | **Cost tracking (USD)** | ✗ | ✗ | ✗ | ✓ via /generation endpoint | Feature — [cost-tracking-spec.md](./cost-tracking-spec.md) |
| 12 | **Session persistence** | ✓ | ✓ | ✗ | ✓ (sessionCodec) | Defer |
| 13 | **Remote execution** | ✓ | ✓ | ✗ | ✗ | N/A |
| 14 | **Preset model count** | 6 + Bedrock | n/a | dynamic | 23 static | Feature — [feature-dynamicmodels-spec.md](./feature-dynamicmodels-spec.md) |
| 15 | **Free model tier** | ✗ | ✗ | ✓ (tagged in dynamic list) | ✓ | Feature — [feature-dynamicmodels-spec.md](./feature-dynamicmodels-spec.md) |
| 16 | **Dynamic model listing** | ✗ | ✗ | ✓ (OpenRouter /models, filtered + tagged) | ✗ | Feature — [feature-dynamicmodels-spec.md](./feature-dynamicmodels-spec.md) |
| 17 | **Model env var / default** | hardcoded default | hardcoded default | ✓ `OPENROUTER_MODEL` → hardcoded default | ✓ `OPENROUTER_MODEL` → hardcoded default | Feature — [feature-dynamicmodels-spec.md](./feature-dynamicmodels-spec.md) |
| 18 | **Skills injection** | ✓ (adapter-utils) | ✓ (adapter-utils) | via AGENTS.md/HEARTBEAT.md | ✓ (SKILL.md scan) | No plan |
| 19 | **CLI tool** | ✓ | n/a | ✗ | ✓ | Future |
| 20 | **taskMarkdown injection** | ✓ | ✓ | ✓ | ✗ | N/A |
| 21 | **Smart cwd resolution** | ✓ | ✓ | ✓ | ✗ | N/A |
| 22 | **`disabledTools` config** | ✗ | ✗ | ✓ | ✗ | N/A |
| 23 | **`extraHeaders` config** | ✗ | ✗ | ✓ | ✗ | N/A |
| 24 | **Cached token tracking** | ✓ | ✓ | ✓ | ✗ | N/A |
| 25 | **`supportsLocalAgentJwt`** | ✓ | ✓ | ✓ | ✓ | N/A |
| 26 | **Monorepo / adapter-utils** | ✓ | ✓ | ✓ | ✗ (standalone npm) | N/A |
| 27 | **Wall-clock run timeout** | ✓ (`timeoutSec` + `graceSec`) | ✓ (`timeoutSec` + `graceSec`) | ✗ | ✗ | Feature — [wall-time-limit-spec.md](./wall-time-limit-spec.md) |

---

## Row Commentary

**Row 1 — Model flexibility.**
`claude-local` is constrained to Anthropic/Bedrock model IDs in its UI list;
`codex-local` is built for OpenAI and requires env var workarounds for other
providers. Both `openrouter-local` and talha route through OpenRouter and
therefore support the same broad set of models in principle. The distinction
is in the UI surface: talha exposes 23 curated presets; `openrouter-local`
will surface a live filtered list via dynamic model listing. Neither adapter
is more open than the other at the API level.

**Row 2 — Tool loop runs in.**
An architectural choice, not a gap. See the In-Process Architecture section
above for full analysis.

**Row 3 — Filesystem tools.**
A concrete advantage over talha. Agents on `openrouter-local` can read, write,
and execute code in a local workspace. The talha model cannot touch the
filesystem — it can only communicate with the Paperclip control plane.

**Row 4 — Paperclip API tools.**
Agents reach the Paperclip API today via `run_command` + curl. This works
reliably with capable models (Claude Sonnet, GPT-4o) but degrades with
cheaper/smaller models that struggle to construct correct API calls from
documentation. Typed tools — adapted from talha's implementation — fix
reliability, improve transcript observability, and unlock approval gating.
Specced; implementation triggered when free-tier models are in active use or
hire_agent governance is required.

**Row 5 — Auto issue state management.**
The talha adapter explicitly calls `update_issue_status` at run start and end.
The Paperclip platform manages state transitions based on exit codes, which is
the correct boundary — this is not adapter responsibility. No plan.

**Row 6 — Issue checkout / pre-lock detection.**
Not optional when Paperclip API write tools are present: the platform enforces
a `sameRunLock` check and rejects write operations with `409` if the current
run does not hold the issue lock. Checkout is a prerequisite for native API
tools, handled as an adapter lifecycle step at run start rather than a
model-facing tool. Covered at no additional cost by the native API tools spec.

**Row 7 — Final output → issue comment.**
The talha adapter posts the final assistant message as an issue comment
explicitly. `openrouter-local` returns `summary` in `AdapterExecutionResult`;
posting it as a comment is the platform's responsibility, consistent with
`claude-local` and `codex-local`. Implementing this in the adapter would
overstep the adapter/platform boundary. No plan.

**Row 8 — Approval gating for hire_agent.**
Cannot be meaningfully enforced against `run_command`. Becomes available as a
clean interception point once typed Paperclip API tools are in place (same spec
as row 4). Default is `autoApprove: false`; operators opt in to autonomous
hiring.

**Row 9 — Runaway loop detection.**
The talha adapter detects repeated identical tool calls and breaks the loop.
The `maxIterations` cap is a blunt equivalent. Sophisticated repeat-call
detection is a quality-of-life improvement but not a correctness issue — a
model stuck in a loop will hit the iteration cap. Future work when loop
pathology is observed in production.

**Row 10 — Reasoning token support.**
Urgent relative to the other gaps because it is directly coupled to dynamic
model listing: once DeepSeek R1, QwQ, and other reasoning models are surfaced
in the model picker, users will select them and their thinking tokens will be
silently discarded. The fix is small — extraction from `message.reasoning`
and `message.reasoning_details`, emission as `kind: "thinking"` transcript
entries — and confined to `execute.ts`. Specced.

**Row 11 — Cost tracking (USD).**
OpenRouter's `/generation` endpoint provides `total_cost` in USD per
completion. Completion IDs are collected during the tool loop and costs are
fetched in parallel after the loop exits, with a short delay for billing
pipeline lag. Best-effort: failures degrade to `costUsd: 0`. The
`provider_name` field from this endpoint is also more reliable than the
`provider` field on the completion object, improving run metadata. Specced.

**Row 12 — Session persistence.**
The talha `sessionCodec` persists the OpenRouter generation ID for display
continuity across heartbeats — it does not provide actual context continuity,
since OpenRouter has no server-side sessions. True session continuity (replaying
message history across runs) is a meaningful capability but a separate,
non-trivial workstream. Deferred until there is a concrete use case.

**Row 13 — Remote execution.**
`claude-local` and `codex-local` support running the agent process on a remote
machine with workspace sync and bridge tunnelling. This is a platform-level
infrastructure feature requiring a fundamentally different execution model. The
in-process loop is intentionally local. N/A.

**Row 14 — Preset model count → dynamic.**
The static 7-model list is replaced by a live fetch from OpenRouter's
`/api/v1/models` endpoint, filtered to tool-capable models and annotated with
capability tags (`[free]`, `[thinking]`, `[vision]`, etc.). Specced.

**Row 15 — Free model tier.**
Zero-cost models (Llama 4, Gemma 3, DeepSeek R1:free, etc.) are included in
the dynamic model list and clearly tagged `[free]`. No separate handling
required. Covered by the dynamic model listing spec.

**Row 16 — Dynamic model listing.**
After implementing the spec, `openrouter-local` is the only adapter with a
live, filtered, annotated model list. `claude-local`, `codex-local`, and talha
all use static lists.

**Row 17 — Model env var / default.**
`OPENROUTER_MODEL` env var is inserted as a middle tier between explicit agent
config and the hardcoded `DEFAULT_OPENROUTER_LOCAL_MODEL` constant. Useful for
server-level model overrides without per-agent reconfiguration. `detectModel`
is wired into `ServerAdapterModule` so the UI can surface the detected model.
Covered by the dynamic model listing spec.

**Row 18 — Skills injection.**
The AGENTS.md / HEARTBEAT.md instruction bundle approach is the correct
mechanism for a monorepo-integrated adapter — it aligns with `adapter-utils`
conventions and matches how `claude-local` and `codex-local` handle skills.
The talha SKILL.md directory scan is designed for standalone operation outside
Paperclip. No plan to change the current approach.

**Row 19 — CLI tool.**
A standalone CLI would be useful for testing the adapter outside a full
Paperclip instance. Not blocking any production use case. Future work.

**Rows 20–24 — Existing advantages.**
`taskMarkdown injection`, `smart cwd resolution`, `disabledTools`, `extraHeaders`,
and `cachedInputTokens` are capabilities present in `openrouter-local` but
absent from talha. No action required; noted for completeness.

**Rows 25–26 — Parity.**
`supportsLocalAgentJwt` is present in both adapters. Monorepo integration is
an intentional structural difference — talha is designed as a standalone npm
package, which is appropriate for a community distribution.

**Row 27 — Wall-clock run timeout.**
`codex-local` and `claude-local` both expose `timeoutSec` (and `graceSec`)
config fields that send SIGTERM/SIGKILL to the child process on expiry.
The in-process model cannot kill itself externally, but an `AbortController`
propagated through the OpenAI client and `ToolContext` provides a practical
equivalent: in-flight HTTP requests are aborted immediately; in-flight
`run_command` subprocesses receive SIGTERM. The net result is that `execute()`
always returns within `timeoutSec` plus one subprocess exit grace period.
Specced.

---

## Planned Features

Five feature specs were produced from this analysis, in approximate
implementation priority order:

### 1. Dynamic Model Selection
**Spec:** [feature-dynamicmodels-spec.md](./feature-dynamicmodels-spec.md)  
**Covers rows:** 14, 15, 16, 17

Replaces the static 7-model list with a live fetch from OpenRouter's
`/api/v1/models` endpoint. Models are filtered to tool-capable only, sorted
with free models first, and annotated with capability tags (`[free]`,
`[thinking]`, `[vision]`, `[structured]`, `[parallel-tools]`). A 5-minute
module-level cache avoids repeated network calls. Adds `OPENROUTER_MODEL` env
var detection via `ServerAdapterModule.detectModel`. Fallback for non-OpenRouter
endpoints returns a sentinel entry prompting manual model entry.

#### Engineering estimate
| | |
|---|---|
| **Complexity** | Low |
| **Risk** | Low — best-effort fetch with static list fallback; worst case is today's behaviour |
| **Lines of code** | ~350 (new `models.ts` ~200, new `models.test.ts` ~140, `index.ts` wiring ~10) |
| **LLM implementation time** | 30–45 minutes |

Primary uncertainty: OpenRouter may silently change field names in the `/models`
response. Mitigated by the static fallback and the fact that filtering on
`supported_parameters` is an inclusion check rather than an exact match.

### 2. Wall-Clock Run Timeout
**Spec:** [wall-time-limit-spec.md](./wall-time-limit-spec.md)  
**Covers row:** 27

Adds a `timeoutSec` config field that bounds total run duration via
`AbortController`. When the timer fires, the in-flight OpenAI HTTP request is
aborted immediately and any in-flight `run_command` subprocess receives SIGTERM.
`execute()` returns `{ timedOut: true, errorCode: "timeout" }`. Brings
`openrouter-local` to parity with `codex-local` and `claude-local` on this
operational dimension. Changes confined to `execute.ts` and `tools.ts`.
Implemented second because it is a safety net — reducing operational risk before
further features increase loop complexity.

#### Engineering estimate
| | |
|---|---|
| **Complexity** | Low-medium |
| **Risk** | Medium — `AbortController` + `AbortSignal` propagation involves multiple async boundaries and cleanup paths. Race conditions between abort firing and tool result receipt need careful handling. OpenAI SDK behaviour under abort should be verified against the version in use |
| **Lines of code** | ~230 (changes to `execute.ts` ~80, changes to `tools.ts` ~50, new test cases ~100) |
| **LLM implementation time** | 45–75 minutes |

Primary uncertainty: ensuring `clearTimeout` and `removeEventListener` are
called in every exit path (normal completion, abort, thrown error). Missing
cleanup causes timer leaks in tests and potentially in production under high
agent concurrency.

### 3. Reasoning Token Support
**Spec:** [reasoning-token-spec.md](./reasoning-token-spec.md)  
**Covers row:** 10

Detects and emits thinking content from model responses as `kind: "thinking"`
transcript entries, making chain-of-thought visible in the Paperclip run viewer.
Handles both `message.reasoning` (string) and `message.reasoning_details`
(typed array), ignoring encrypted entries. Adds optional `reasoning` config
field for request-side effort/token-budget control. Urgent given coupling to
dynamic model listing — reasoning models will be exposed in the picker once
that spec is implemented.

#### Engineering estimate
| | |
|---|---|
| **Complexity** | Low |
| **Risk** | Low — purely additive; no existing behaviour changes. Worst case is thinking tokens not extracted, which is the current state |
| **Lines of code** | ~180 (changes to `execute.ts` ~80, new test cases ~100) |
| **LLM implementation time** | 20–35 minutes |

Primary uncertainty: the `reasoning_details` array structure is documented but
not battle-tested across all OpenRouter providers. Graceful fallback to
`message.reasoning` string covers the common case.

### 4. USD Cost Tracking
**Spec:** [cost-tracking-spec.md](./cost-tracking-spec.md)  
**Covers row:** 11

Fetches actual USD cost from OpenRouter's `GET /api/v1/generation?id=...`
endpoint after each run, replacing the hardcoded `costUsd: 0`. Completion IDs
are collected during the tool loop; costs are fetched in parallel with an 800ms
delay for billing pipeline lag. Best-effort: failures degrade to `costUsd: 0`
without affecting run outcome. Also improves `provider` attribution via the
more reliable `provider_name` field. OpenRouter-only; non-OpenRouter endpoints
unaffected.

#### Engineering estimate
| | |
|---|---|
| **Complexity** | Low |
| **Risk** | Low-medium — the 800ms billing lag delay is an estimate; OpenRouter gives no SLA on generation record availability. Graceful degradation means cost simply shows as 0 if the record isn't ready |
| **Lines of code** | ~180 (changes to `execute.ts` ~80, new test cases ~100) |
| **LLM implementation time** | 20–35 minutes |

Primary uncertainty: the billing pipeline delay. If 800ms is too short in
practice, `costUsd` will silently be 0 for some runs with no user-visible
error. Could be addressed with a single retry if this proves to be an issue
in production.

### 5. Native Paperclip API Tools
**Spec:** [native-api-tools-spec.md](./native-api-tools-spec.md)  
**Covers rows:** 4, 6, 8

Adds 9 typed, first-class Paperclip control-plane tools alongside the existing
filesystem tools, creating a hybrid model where the model uses structured tools
for known API operations and `run_command` for everything else. Improves
reliability for lower-tier models, makes Paperclip operations legible in
transcripts, and enables approval gating for `hire_agent`. Includes a
`PaperclipApi` HTTP client adapted from the talha implementation, issue checkout
at run start (addressing row 6 as a prerequisite for write operations), and
`autoApprove` config for autonomous agent hiring. **Low priority until free-tier
or smaller models are in active use, or hire_agent governance is required.**

#### Engineering estimate
| | |
|---|---|
| **Complexity** | Medium-high |
| **Risk** | Medium-high — the checkout/lock flow depends on correct understanding of Paperclip's `sameRunLock` protocol; the approval gating path must match the approvals API shape exactly. Integration testing requires a running Paperclip instance. The talha implementation provides a working reference but requires adaptation |
| **Lines of code** | ~900 (new `paperclip-api.ts` ~150, new `paperclip-tools.ts` ~350, changes to `execute.ts` ~40, changes to `tools.ts` ~15, new test files ~350) |
| **LLM implementation time** | 2–3 hours |

Primary uncertainty: the `sameRunLock` checkout behaviour under concurrent
runs. Correct handling of 409 responses and clean abort without leaving the
issue in a bad state requires either access to the Paperclip server source or
careful empirical testing against a live instance.
