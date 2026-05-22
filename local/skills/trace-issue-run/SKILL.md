---
name: trace-issue-run
description: >
  Diagnose a Paperclip agent run by fetching issue and transcript data using
  the Paperclip MCP server. Use when given a Paperclip issue URL and asked to explain
  what an agent did, why it stalled, or what went wrong. Performs the full
  diagnostic sequence: issue fetch → runs list → transcript parse → comment
  review → child issue traversal.
---

# Trace Issue Run

Given one or more Paperclip issue URLs, pull the full run trace using the Paperclip MCP tools and produce a structured diagnosis.

## Extracting the identifier

Issue URLs follow the pattern `http://host/{project}/issues/{IDENTIFIER}`.
Extract the last path segment (e.g. `LINAA-33`). The MCP tools accept identifiers
directly — no UUID needed for lookup.

## Diagnostic sequence

Run these steps for every issue URL supplied. Use concurrent tool calls where there are no dependencies.

### 1. Fetch the issue

Use the `paperclipGetIssue` MCP tool:
```json
{
  "ServerName": "paperclip-local",
  "ToolName": "paperclipGetIssue",
  "Arguments": {
    "issueId": "{IDENTIFIER}"
  }
}
```

Record:
- `status`, `assigneeAgentId`, `startedAt`, `completedAt`, `cancelledAt`
- `executionRunId`, `checkoutRunId`, `executionLockedAt`
- `blockerAttention` — note `state`, `unresolvedBlockerCount`
- `parentId`, and `relatedWork` for child identifiers

### 2. Fetch all runs

Since there is no dedicated MCP tool for listing runs, use the `paperclipApiRequest` MCP tool:
```json
{
  "ServerName": "paperclip-local",
  "ToolName": "paperclipApiRequest",
  "Arguments": {
    "method": "GET",
    "path": "/api/issues/{IDENTIFIER}/runs"
  }
}
```

Lists every heartbeat run ever associated with this issue. For each run note `id`, `status`, `startedAt`, `completedAt`, `exitCode`. Work most-recent-first.

### 3. Fetch the transcript for each run

Use the `paperclipApiRequest` MCP tool to get the run log:
```json
{
  "ServerName": "paperclip-local",
  "ToolName": "paperclipApiRequest",
  "Arguments": {
    "method": "GET",
    "path": "/api/heartbeat-runs/{runId}/log"
  }
}
```

Returns newline-delimited JSON. Each line is a transcript entry — parse and display in readable form, grouped by `kind`:

| kind          | what it means                                     |
| ------------- | ------------------------------------------------- |
| `init`        | run started — note `model`, `sessionId`           |
| `system`      | system prompt loaded — note fragment count        |
| `assistant`   | agent text output                                 |
| `tool_call`   | tool invoked — note `name`, `input`               |
| `tool_result` | tool response — flag `isError: true` entries      |
| `result`      | final outcome — note `subtype`, `isError`, `text` |

### 4. Fetch comments

Use the `paperclipListComments` MCP tool:
```json
{
  "ServerName": "paperclip-local",
  "ToolName": "paperclipListComments",
  "Arguments": {
    "issueId": "{IDENTIFIER}"
  }
}
```

Agent comments often contain handoff notes, escalation summaries, or the final status table from a rollcall/delegation run.

### 5. Recurse into child issues

If `relatedWork` contains child identifiers, fetch those issues too and apply the same sequence at one level of depth unless the user asks for more.

## What to surface in the diagnosis

Structure the output as:

**Issue state** — was it picked up (`executionRunId` set)? did it start (`startedAt`)? how did it end (`status`, `exitCode`)?

**Run timeline** — how many runs, when, how long each took.

**Transcript highlights** — last assistant message, last tool call, any `isError` tool results, final `result` entry.

**Delegation trace** — were child issues created? did they get picked up? (check `executionRunId` on each child)

**Root cause** — one paragraph summarising what the agent did, where it stopped, and the likely reason.

## Known environment facts

- Company ID: can be found in the environment variable `PAPERCLIP_COMPANY_ID`
