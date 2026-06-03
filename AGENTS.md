# AGENTS

Load the repo-local skills before you start changing code when they match the task.

## Collaboration Preferences

- Do not end responses with soft follow-up prompts like “if you want” / “if you’d like” / “if you愿意”.
- Distinguish clearly between a working draft for internal thinking and a polished document that can be shared directly. Do not leave meta-writing scaffolding in shareable docs.
- When the user asks to run a process "in the background" and watch it, keep it simple: run it in the current Codex tool session and monitor its output. Do not switch to `launchctl`, `tmux`, `screen`, daemonization, or other system-level service management unless the user explicitly asks for a persistent system service.

## Design Context

### Users

NexAgent UI is primarily for the project's owner and developer-operators who need to inspect, debug, and steer a long-running AI agent. They use the interface while working on real agent runs, trace investigation, memory/skill/tool evolution, gateway status, and background tasks. The job is fast operational understanding: what happened, why it happened, what changed, and what can be safely done next.

### Brand Personality

NexAgent should feel self-evolving, technical, and trustworthy. The interface should communicate that this is not a one-shot chatbot wrapper, but a living agent runtime with memory, tools, skills, traces, background work, and source-level evolution. The emotional goal is confidence with a hint of future-facing agency: users should feel that the system is observable, durable, and capable of improving over time.

### Aesthetic Direction

Use a developer-first control-plane aesthetic with a self-evolving agent identity. Prefer dense, structured operational surfaces over landing-page composition. Trace/debug surfaces can lean terminal-like, with event streams, monospace details, and clear status color. Broader console surfaces should support both dark and light themes, with dark mode as the richer debugging experience and light mode as a clean operational alternative.

Avoid generic SaaS dashboards, decorative gradient-orb backgrounds, oversized marketing heroes, and card-heavy layouts that hide execution evidence. Visual interest should come from runtime structure: timelines, state transitions, lineage, tool activity, memory layers, and evolution paths.

### Design Principles

1. Evidence first: every UI should make the underlying runtime state, trace, event, or file-backed source visible before interpretation.
2. Dense but calm: optimize for scanning and repeated developer use; avoid spacious marketing layouts and decorative filler.
3. Self-evolution should be legible: show memory, skills, tools, code upgrades, and lineage as connected system layers, not isolated widgets.
4. Theme-aware by default: support dark and light modes; maintain WCAG AA contrast, reduced-motion friendliness, and color-blind-safe status signals.
5. Operational controls need clear consequences: actions that affect runtime, memory, tools, skills, or code should show scope, current state, and result.

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
