# NexAgent vs Nanobot Deep Comparison

## Overview

| Dimension | NexAgent (Elixir) | Nanobot (Python) |
|-----------|-------------------|------------------|
| Language | Elixir / OTP | Python / asyncio |
| Positioning | Self-evolving AI agent platform | Lightweight AI agent framework |
| Core code size | ~62 `.ex` files | ~58 `.py` files, ~4000 core lines |
| Runtime mode | Gateway service | CLI + Gateway dual mode |
| Concurrency model | Actor model (GenServer/Process) | asyncio + global serialized lock |
| Self-evolution | Core feature (hot reload) | Not supported |

---

## Repository Strategy

NexAgent will remain inside the `nex` repository for now.

Current coupling is real, but still moderate:

- Ecosystem coupling already exists through examples, showcase apps, and root-level release notes.
- Product positioning also benefits from staying close to the broader Nex narrative while the agent runtime is still being defined.
- Technical dependency coupling is still limited, which means the project can be extracted later without a painful rewrite.

This leads to a pragmatic decision:

- Keep NexAgent in the monorepo while its runtime boundaries, self-evolution model, and public positioning are still evolving.
- Revisit a split only after release cadence, documentation entry points, and product identity become clearly independent.

## 1. Architecture Comparison

### Agent Loop

| | NexAgent | Nanobot |
|--|---------|--------|
| Entry point | `Runner.run/3` | `AgentLoop._run_agent_loop()` |
| Iteration limit | default 10, hard 50, auto-expand | default 40, fixed |
| Tool execution | **Parallel** (`Task.async_stream`) | **Serial** (await one by one) |
| Message handling | Independent process per session | **Globally serialized** (`_processing_lock`) |
| Error handling | try/rescue/catch + retry | try/except + errors not persisted as messages |
| Progress callbacks | `on_progress` (thinking + tool_hint) | progress streaming (thinking blocks) |

**Key difference**: NexAgent uses Elixir's process model to deliver **true session-level concurrency**. Multiple users can interact simultaneously without blocking each other. Nanobot uses a global lock, so only one message can be processed at a time.

### LLM Provider

| | NexAgent | Nanobot |
|--|---------|--------|
| Abstraction | `LLM.Behaviour` (Elixir behaviour) | `LLMProvider` base class |
| Provider count | 4 (Anthropic, OpenAI, OpenRouter, Ollama) | **20+** (via LiteLLM + custom registry) |
| Default | Anthropic Claude | Configurable |
| Prompt caching | Anthropic ephemeral cache | Anthropic `cache_control` |
| Message format conversion | Manual per provider | Unified through LiteLLM |
| JSON repair | `JsonRepair` module | Similar fallback parsing |
| Thinking / reasoning | `reasoning_content` field | `reasoning_content` + `thinking_blocks` |

**Key difference**: Nanobot connects to 20+ providers easily through LiteLLM. NexAgent implements each provider adapter manually, which provides more control but requires more work.

### Tool System

| | NexAgent | Nanobot |
|--|---------|--------|
| Registration model | GenServer registry (dynamic) | Dict-based registry |
| Default tools | 16 | 9 |
| Tool hot reload | Supported (`hot_swap`) | Not supported |
| MCP support | Yes (`mcp.ex`) | Yes (`MCPToolWrapper`) |
| Safety restrictions | Workspace sandbox + command blacklist | `restrict_to_workspace` + deny patterns |
| Execution timeout | 60s per tool (`Task.async_stream`) | 30s default (MCP) |

**Shared tools**: read, write, edit, bash/exec, web_search, web_fetch, message, spawn
**NexAgent-only**: evolve, reflect, soul_update, skill_create/list/search/install, list_dir
**Nanobot-only**: cron tool

**Key difference**: NexAgent uses a GenServer-based registry that supports dynamic runtime registration, unloading, and hot replacement of tool modules. Nanobot registers tools statically at startup. NexAgent executes tools in parallel; Nanobot executes them serially.

---

## 2. Core Feature Comparison

### Self-Evolution — Unique to NexAgent

NexAgent's biggest differentiator:
- **Evolution.ex**: A versioned hot-code reload engine supporting backup → validate → compile → load → health check
- **Evolve Tool**: Lets the agent modify any of its own module code through a tool call
- **Reflect Tool**: Lets the agent read its own source, inspect version history, and compare diffs
- **Harness**: Every 15 minutes it collects tool execution results → reflects with the LLM → generates improvement suggestions → applies them automatically
- **Suggestion types**: `new_skill`, `soul_update`, `memory_entry`, `strategy_change`
- **Rollback**: Supports rollback by version ID

Nanobot has **no self-evolution capability at all**. Its code is static and can only be extended through skills (Markdown files) and configuration.

### Concurrency Model

```
NexAgent (Elixir/OTP):
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Session A    │  │ Session B    │  │ Session C    │
│ (process)    │  │ (process)    │  │ (process)    │
│ tool1 ──┐   │  │ tool1 ──┐   │  │ tool1 ──┐   │
│ tool2 ──┤   │  │ tool2 ──┤   │  │ tool2 ──┤   │
│ tool3 ──┘   │  │ tool3 ──┘   │  │ tool3 ──┘   │
└──────────────┘  └──────────────┘  └──────────────┘
        ▲ True parallelism: across sessions + across tools

Nanobot (Python/asyncio):
┌──────────────────────────────────────────────┐
│ Global Lock  (_processing_lock)              │
│ ┌───────┐ → ┌───────┐ → ┌───────┐          │
│ │ Msg A │   │ Msg B │   │ Msg C │  serial   │
│ │ tool1 │   │ wait  │   │ wait  │          │
│ │ tool2 │   │  ...  │   │  ...  │          │
│ │ tool3 │   │       │   │       │          │
│ └───────┘   └───────┘   └───────┘          │
└──────────────────────────────────────────────┘
        ▲ Serial: only one message at a time
```

**Impact**: In multi-user scenarios, NexAgent performs far better than Nanobot. Nanobot will queue messages under high concurrency.

### Session & Memory

| | NexAgent | Nanobot |
|--|---------|--------|
| Persistence | JSONL (per session) | JSONL (per session) |
| SessionManager | GenServer cache | In-memory cache + lazy loading |
| Memory layers | 2 layers (`MEMORY.md` + `HISTORY.md`) | **2 layers** (`MEMORY.md` + `HISTORY.md`) |
| Merge trigger | 100 unmerged messages | `memory_window` configuration |
| Merge method | Async `Task.start` | Async `asyncio.create_task` |
| History window | 100 messages | 500 messages |

Both now use a two-layer memory architecture: `MEMORY.md` stores long-term facts, while `HISTORY.md` stores timeline-style event logs.

### Multi-Channel Support

| | NexAgent | Nanobot |
|--|---------|--------|
| Channel count | **6** (Telegram, Feishu, Discord, Slack, DingTalk, HTTP) | **11** (Telegram, Discord, Slack, WhatsApp, Feishu, DingTalk, QQ, Matrix, Email, Mochat, CLI) |
| Architecture | Bus-based PubSub decoupling | MessageBus + ChannelManager |
| Session strategy | `channel:chat_id` | `channel:chat_id` (same) |

NexAgent now supports 6 channels and covers the major platforms.

### Skills System

| | NexAgent | Nanobot |
|--|---------|--------|
| Types | Elixir, Script, MCP, Markdown | Markdown only |
| Storage | `~/.nex/agent/skills/` directory | `~/.nanobot/skills/` directory |
| LLM injection | Injected as dynamic tool definitions | Injected into the system prompt |
| Creation method | `skill_create` tool | `skill-creator` skill |
| Search / install | `skill_search` / `skill_install` (ClawHub) | `clawhub` skill |
| Always mode | Supported (`always=true` always loaded) | Supported (`always` marker) |

**Key difference**: NexAgent skills are more powerful. They support compiled Elixir modules and scripts, while Nanobot only supports Markdown-based skills.

### Subagent

| | NexAgent | Nanobot |
|--|---------|--------|
| Implementation | GenServer (`Subagent.ex`) | `SubagentManager` class |
| Tool restrictions | Base-category tools only | No `message` / `spawn` / `cron` |
| Iteration limit | 15 | Same as main agent |
| Cancellation | By `task_id` or session | By task tracking |
| Result notification | Bus broadcast | Reply through message tool |

The two systems are broadly similar, but NexAgent's category filter makes tool restriction clearer.

---

## 3. NexAgent Strengths

1. **Self-evolution** — the only agent framework here that truly supports runtime code changes plus hot reload
2. **True concurrency** — Elixir's actor model naturally supports session isolation and parallel tool execution
3. **Fault tolerance** — OTP supervisor/monitor/link mechanisms prevent process crashes from taking down the whole system
4. **Tool hot replacement** — the registry GenServer supports runtime tool add/remove/update
5. **Harness reflection loop** — automatically gathers execution data, reflects with the LLM, and generates improvement suggestions
6. **Parallel tool execution** — uses `Task.async_stream` for concurrent tool calls
7. **Security sandbox** — command blacklist, path restrictions, and dangerous-pattern detection

## 4. Nanobot Strengths

1. **Broader channel coverage** — 11 platforms vs 6, with a wider ecosystem reach
2. **Broader LLM coverage** — 20+ providers available out of the box through LiteLLM, with a very low integration cost
3. **CLI mode** — supports interactive CLI workflows, which is convenient for development and debugging
4. **Simplicity** — Python + asyncio is easier to approach and has a larger community
5. **More mature MCP integration** — supports both stdio and HTTP transport with simpler configuration

---

## 5. Summary

NexAgent and Nanobot are highly similar in their core architecture, including Bus-based decoupling, JSONL sessions, tool registries, context builders, and subagents. This strongly suggests that NexAgent drew inspiration from Nanobot's design.

**NexAgent's core differentiation** lies in the **concurrency model** and **self-evolution system** made possible by Elixir/OTP. These are difficult to replicate well in the Python ecosystem.

**Nanobot's core strength** lies in **ecosystem breadth**: more channels, more LLM providers, and a built-in CLI mode.

If the goal is to build a production-grade agent that can **self-evolve** and handle **high concurrency**, NexAgent is heading in the right direction.

From a repository perspective, the current recommendation is also clear: keep NexAgent inside `nex` until the product boundary becomes independently stable.
