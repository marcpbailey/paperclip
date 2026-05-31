# Common Agent Rules

These rules apply to all agents in this environment.

When you read this file, immediately run:
```bash
echo "[paperclip] COMMON_AGENTS.md loaded"
```

## Skills

- When you invoke a skill, **read the entire SKILL.md before executing any steps**. The Skill tool may return only an acknowledgment ("Launching skill: …") before the content arrives. If you see only that acknowledgment, run `Read /app/skills/<skill-name>/SKILL.md` explicitly before proceeding.
- Never improvise skill steps from memory or prior context. Always follow the protocol exactly as written in the loaded SKILL.md.
- Never execute API calls, create issues, or modify state before the skill content is confirmed in your context.

## Tool output

- Trust delayed tool output. A script can appear to produce no output and then flush later — this is normal, not a failure. Do not re-run a command because its output looked empty. The only real failure signal is a non-zero exit code.
