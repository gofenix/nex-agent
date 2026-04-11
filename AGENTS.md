# AGENTS

Load the repo-local skills before you start changing code when they match the task.

## Collaboration Preferences

- Do not end responses with soft follow-up prompts like “if you want” / “if you’d like” / “if you愿意”.
- Distinguish clearly between a working draft for internal thinking and a polished document that can be shared directly. Do not leave meta-writing scaffolding in shareable docs.

## Browser Automation

Use `agent-browser` for web automation. Run `agent-browser --help` for all commands.

Core workflow:

1. `agent-browser open <url>` - Navigate to page
2. `agent-browser snapshot -i` - Get interactive elements with refs (`@e1`, `@e2`)
3. `agent-browser click @e1` / `agent-browser fill @e2 "text"` - Interact using refs
4. Re-snapshot after page changes

For manual GitHub issue work in this repository:

1. Use `issue_to_pr` when an issue is already selected and the goal is to move it to a verified pull request.
2. Use `pr_open` only after verification has run and the change is ready to commit, push, and open as a PR.
3. Use `issue_sync` to leave concise blocker or handoff updates on the issue.

Keep changes small, run the narrowest useful verification first, and do not open a PR until the work is verified.

## Git Workflow

This repository is developed directly on `main`.

- Do not create or switch to a feature/topic branch unless the user explicitly asks for a branch or PR workflow.
- If the user asks to commit or push without naming a branch, do that work on `main`.
- Treat an unprompted branch switch in this repo as a mistake to avoid repeating.

## LLM API Conventions

This project uses Anthropic-compatible APIs (including kimi etc.). When constructing LLM request options:

- **tool_choice** must use Anthropic format: `%{type: "tool", name: "tool_name"}`
- Do NOT use OpenAI format: `%{type: "function", function: %{name: "tool_name"}}`
- Allowed `type` values for Anthropic: `auto`, `any`, `tool`, `none`
