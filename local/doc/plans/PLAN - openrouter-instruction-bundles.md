# PLAN - openrouter-instruction-bundles
## Enable Instruction Bundles for OpenAI/OpenRouter Adapter

To allow LinkCast agents to use local instruction bundles (`AGENTS.md`), the `openai` adapter must claim the `supportsInstructionsBundle` capability. 

This ensures that Paperclip treats the adapter as a "local-aware" provider capable of reading and managing agent-specific instruction files from the company package.

## Proposed Changes

### [adapter-openai](file:///Users/marc/Projects/LinkCast/crew/paperclip/adapter-openai)

#### [MODIFY] [index.ts](file:///Users/marc/Projects/LinkCast/crew/paperclip/adapter-openai/src/server/index.ts)
- Add `supportsInstructionsBundle: true` to the exported `ServerAdapterModule` object.
- Add `requiresMaterializedRuntimeSkills: true` (ensures skills are correctly injected into the execution context).

## Execution Steps

1.  **Modify Source**: 
    Update the server entry point in the adapter source code.
2.  **Rebuild Adapter**:
    ```bash
    cd ~/Projects/LinkCast/crew/paperclip/adapter-openai
    pnpm build
    ```
3.  **Reload in Paperclip**:
    - Open the Paperclip UI: `http://localhost:3100`
    - Go to **Instance Settings > Adapters**.
    - Click **Reload** on the `openai` adapter.
4.  **Verify**:
    - Navigate to any agent (e.g., Starlord or Fury).
    - Confirm the **Instructions** tab is now visible.
    - Confirm you can see the content from the local `AGENTS.md` files.

## Verification Plan
- **UI Check**: Confirm the "Instructions" tab appears for agents using the `openai` adapter.
- **Import Check**: Re-run the `company import --dry-run`. It should correctly associate the instruction bundles with the agents.
