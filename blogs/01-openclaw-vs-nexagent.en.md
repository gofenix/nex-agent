# After Playing with OpenClaw, I Decided to Plant My Own Tree

> OpenClaw showed the world the future of AI Agents. But it got me wondering: if an Agent is going to stick with me for a decade, what should its architecture look like?

---

## TL;DR

**OpenClaw's [310k stars](https://github.com/openclaw/openclaw) are well-deserved.**

It proves that the "personal AI Agent" direction is right—that everyday users are willing to pay for an "AI that can actually do work." As a long-time AI observer, seeing that red lobster logo take over the internet makes me genuinely happy. It means Agents are finally moving from a niche toy to the mainstream.

I spun one up myself. But using it surfaced some interesting issues that got me thinking: **If an Agent is meant to be a 24/7 "companion" rather than just a "tool"—and if it needs to get smarter over time—how should its underlying architecture change?**

There's no single right answer. OpenClaw proved the demand using TypeScript/Node.js. I wanted to explore a different path using Elixir/OTP.

So I built [NexAgent](https://github.com/gofenix/nex-agent).

**This isn't meant to compete with OpenClaw. It's an experiment focused entirely on the "long-running Agent" niche.**

---

## My Experience Raising a Lobster

Like everyone else, I found OpenClaw on Twitter.

The red lobster logo, [310k stars](https://github.com/openclaw/openclaw), the "AI digital employee" pitch—it felt straight out of Iron Man (hello, JARVIS).

I installed it right away, hooked up a Telegram Bot, and gave it a task: "Check my GitHub Issues every morning at 8 AM and ping the high-priority ones to Lark."

**Early Days: Pure Magic**

- Waking up to find my Issues neatly categorized.
- Asking "Any bugs today?" on Telegram and seeing it actually remember yesterday's context.
- Felt a solid 20% bump in my quality of life.

**After a While: Pleasant, but Puzzling**

- The capabilities are undeniably powerful—vision, tool usage, all super smooth.
- But after running for a while, response times degraded from instant to 3-5 second delays.
- Needed occasional restarts to get back to normal.
- I thought I misconfigured something and spent hours reading docs.

**Then Came the Crash**

- Woke up one morning to silence.
- Checked the logs: the process had crashed from an OOM (Out of Memory) spike.
- I restarted it, but it had amnesia—all the context built up over the week was gone.
- That was a bummer. The "AI that remembers everything" clearly had its limits.

**That Led Me to a Different Question**

- What if I don't just want to *use* an Agent, but *raise* it long-term?
- It needs 24/7 rock-solid uptime.
- It should compound its intelligence, not wipe the slate clean on every reboot.
- It needs to self-evolve instead of waiting for author updates.

That’s when another tech stack came to mind.

---

## Why Elixir/OTP?

Choosing TypeScript/Node.js for OpenClaw was the right move. It dramatically lowered the barrier to entry and brought more than 310k people into the project. That's how open source wins.

But I kept wondering: **if the endgame is a "system that never goes down", what else is out there?**

That led me to Elixir and OTP. Not for novelty's sake, but because OTP (Open Telecom Platform) was literally built for telecom switches: systems that *must* run 24/7, stay resilient, and support hot code upgrades.

| Scenario | Node.js Approach | OTP Approach |
|---------|-----------------|--------------|
| Process Management | Single process + external restart | Supervision tree auto-restart |
| Memory Isolation | Same process space | Each task runs in isolated process |
| Hot Updates | Restart the service | Zero-downtime hot reload |
| Error Recovery | Manual intervention | Auto-recovery + graceful degradation |

It’s not about which stack is better—it’s about **optimizing for different use cases**.
- OpenClaw optimizes for accessibility, putting Agents in everyone's hands.
- NexAgent optimizes for extreme stability, exploring what long-term AI companionship looks like.

---

## Core Experiments with NexAgent

I rewrote the Agent's core in Elixir and ran a few tests:

### Experiment 1: Uptime

I left NexAgent running on my local machine for an extended period:

- **Stability**: Rock solid, zero memory leaks.
- **Latency**: Consistently fast, no degradation over time.
- **Resilience**: When a tool crashed, it restarted instantly without taking down the main loop.

Zero manual restarts. OTP's supervision tree makes the system far easier to operate over long periods.

### Experiment 2: Hot Reloading in the Wild

My AMap weather tool suddenly broke, throwing API permission errors.

The Agent self-diagnosed the issue: the API key was bound to iOS, but it was making server-side calls. It autonomously patched its own source code, swapping the logic to read a Web Service key instead.

Four minutes later, it successfully pulled the weather for Shenzhen. No server restart. The chat session never dropped.

**Here's the actual screenshot:**
![Agent auto-fixing AMap weather tool](images/amap-weather-fix.png)

From diagnosing the bug to writing the fix and hot-reloading the module—zero human intervention.

### Experiment 3: Self-Evolution Pipeline

NexAgent ships with a built-in pipeline for self-improvement:

1. **Reflect**: Read the source code of any internal module.
2. **Analyze**: Figure out what's broken and draft a fix.  
3. **Upgrade**: Apply the patch and hot-reload on the fly.

This means that when tool logic needs to change, for example because an external API changes its response format, the Agent can inspect its own code, patch it, and update itself in memory without me having to restart the daemon.

The mechanism works flawlessly. I'm currently exploring more complex "fully autonomous repair" scenarios.

---

## Two Ways to "Raise" an AI

Raising OpenClaw is like keeping a **lobster**:
- Grows fast, packed with features.
- The immediate UX is mind-blowing.
- But it requires a bit of maintenance and occasional reboots.

Raising NexAgent is like planting a **tree**:
- Grows slowly and demands more upfront investment.
- But once it takes root, it stays with you for years.
- It remembers your quirks and actually "gets" you over time.

**Which one fits you?**

Depends on what you want:
- Want to quickly experience the bleeding edge of AI Agents? **Use OpenClaw.**
- Need a 24/7 hyper-stable digital assistant? **Check out NexAgent.**
- Fascinated by self-evolving AI that accumulates knowledge over years? **That's what NexAgent is exploring.**

---

## Under the Hood of NexAgent

### 1. Supervision Trees: Crash and Recover

```elixir
# lib/nex/agent/application.ex
children = [
  NexAgent.InfrastructureSupervisor,
  NexAgent.WorkerSupervisor,
  NexAgent.Gateway
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

If the infrastructure tier crashes, all dependent Workers restart. If a single tool crashes, only that specific tool's process restarts. The main Agent loop keeps running.

### 2. Process Isolation: Each Task Runs in Its Own Process

```elixir
# lib/nex/agent/tool/registry.ex:181
Task.Supervisor.start_child(NexAgent.ToolTaskSupervisor, fn ->
  tool_module.execute(args)
end)
```

Every single tool execution gets its own lightweight process. Crashes don't affect the main loop.

### 3. Hot Reloading: Upgrades on the Fly

```elixir
# lib/nex/agent/code_upgrade.ex:39
with :ok <- maybe_validate_code(code),
     :ok <- create_backup(module, source_path),
     :ok <- write_source(source_path, code),
     {:ok, hot_reload} <- compile_and_load(module, code),
     :ok <- maybe_health_check(module) do
  {:ok, %{version: version, hot_reload: hot_reload}}
else
  {:error, reason} ->
    _ = rollback(module)  # Auto rollback on failure
    {:error, to_error(reason)}
end
```

### 4. Dual-Layer Memory

- **MEMORY.md**: Long-term state (project context, user quirks).
- **HISTORY.md**: Grep-able conversation logs.

Powered by **async consolidation**: When a chat gets too long, the Agent spins up a background process to summarize the history and extract facts into long-term memory. Zero latency impact on your active chat.

---

## The Six-Layer Evolution Model

NexAgent doesn't just evolve in one way. It has six layers of growth:

1. **SOUL**: Personality and core values.
2. **USER**: Your profile and how you like to collaborate.
3. **MEMORY**: Long-term context and project domain knowledge.
4. **SKILL**: Reusable workflows it has learned.
5. **TOOL**: Hardcoded integrations and tools.
6. **CODE**: The actual Elixir source code.

Every layer compounds over time, and each can evolve independently.

---

## Quick Start

Want to take it for a spin?

```bash
# 1. Install Elixir (~> 1.18)
# 2. Clone repo
git clone https://github.com/gofenix/nex-agent.git
cd nex-agent
mix deps.get

# 3. Initialize
mix nex.agent onboard

# 4. Configure config file

# 5. Start gateway
mix nex.agent gateway
```

More docs: [GitHub Repo](https://github.com/gofenix/nex-agent)

---

## Closing Thoughts

OpenClaw opened our eyes to what AI Agents can do. That's a massive win for the whole industry.

NexAgent is simply probing a specific niche: **If an Agent is meant to be a long-term companion, how should we build it?**

[310k people are raising lobsters](https://github.com/openclaw/openclaw), experiencing what it feels like to have AI at their fingertips.

I'm planting a tree, waiting for the day it grows into a canopy.

**Two different paths, one shared goal: weaving AI seamlessly into our lives.**

---

**Links**:
- NexAgent GitHub: https://github.com/gofenix/nex-agent
- OpenClaw GitHub: https://github.com/openclaw/openclaw

---

*Last updated: 2026-03-13*
