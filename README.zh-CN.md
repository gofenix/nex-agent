<div align="center">
  <h1>NexAgent</h1>
  <p><strong>持续进化的专属 AI Agent</strong></p>
  <p>它可以长期运行，在你常用的聊天应用中工作，调用工具，保留上下文记忆，并在真实使用中持续进化。</p>
  <p><a href="./README.md">English README</a></p>
</div>

NexAgent 是一个面向真实使用场景的 AI Agent。

它不是只在终端里跑一轮对话的脚本，也不只是给大模型包一层 prompt。NexAgent 的目标更明确一些: 让 Agent 长期在线、进入聊天应用、拥有记忆与工具、管理定时任务与后台工作，并且在真实使用中持续进化。

这个项目当前最重要的两条方向是:

- **自主进化**: 不只做 prompt engineering，也做 memory、skills、tools，以及 agent 自身代码的反思与进化。
- **Elixir/OTP**: 基于监督树、GenServer、进程隔离和热代码加载构建，强调容错、并发、长期运行与系统可靠性。

## At a Glance

如果只看一眼，NexAgent 可以理解成三层:

- **你看到的**: 一个长期在线、能在聊天应用里工作的 AI Agent
- **它会做的**: 记忆、工具调用、技能扩展、定时任务、后台子任务
- **它为什么能长期工作**: Elixir/OTP + 自我进化能力

```mermaid
flowchart TD
    A["Chat Apps<br/>Telegram / Feishu / Discord / Slack / DingTalk"] --> B["Gateway"]
    B --> C["InboundWorker"]
    C --> D["Runner"]
    D --> E["Sessions + Memory"]
    D --> F["Tools + Skills"]
    D --> G["Cron + Subagent"]
    D --> H["Reflect + Evolve"]
    H --> I["Evolution + Surgeon"]
```

## What You Can Build

| 场景 | NexAgent 在做什么 |
| --- | --- |
| 长期在线助手 | 持续待在聊天应用里，按会话保存上下文和历史 |
| 个人知识助手 | 把长期记忆、历史记录和检索结合在一起 |
| 自动化任务助手 | 通过 cron 管理定时提醒、周期任务和后台工作 |
| 可成长的 Agent | 通过 skills、tools 和代码级进化不断扩展能力 |

## Key Features

| 能力 | 说明 |
| --- | --- |
| **Self-evolving by design** | 通过 `reflect`、`evolve`、`soul_update`、skills 和 tools，让 Agent 不停留在静态能力集 |
| **Long-running sessions** | 按 `channel:chat_id` 管理会话，支持长期记忆、历史沉淀与会话隔离 |
| **Works in your chat apps** | 当前支持 Telegram、Feishu、Discord、Slack、DingTalk |
| **Tools, skills, and memory built in** | 内置文件、Shell、Web、消息、记忆、定时任务、技能管理等能力 |
| **Background work included** | 支持 cron 定时任务和 subagent 子代理 |
| **Built on Elixir/OTP** | 通过监督树、服务进程和热更新机制支撑真实运行环境 |

## Why NexAgent

很多 Agent 项目擅长“完成一次任务”。NexAgent 更关心另一类问题: 当 Agent 真正进入聊天环境、开始长期运行之后，会话、记忆、任务、容错和进化该怎么组织。

### Why self-evolving

NexAgent 的差异不在“多一个工具”或“多一个模型”，而在它把进化能力做成了系统核心。

它的进化路径是分层的:

- `SOUL.md`: 调整行为方式、表达风格和价值观
- `MEMORY.md` / `HISTORY.md` / 每日日志: 积累长期经验
- Skills: 把新能力做成可复用能力
- Tools: 扩展 Agent 能做的事情
- Code: 通过 `reflect` 和 `evolve` 修改 agent 自身实现

这意味着 NexAgent 的“自进化”不是一句口号，而是从上下文、记忆到能力再到源码的完整链路。

### Why Elixir/OTP

如果 Agent 只是偶尔跑一轮推理，语言和架构影响没那么大。但如果它要长期在线、管理多个聊天入口、做后台任务、在出错后恢复，并且还要热更新自己，OTP 的价值就会直接变成产品能力的一部分。

NexAgent 当前已经明确建立在这条路线之上:

- `Application` 监督树管理基础设施、worker 和 channel 生命周期
- `Gateway` 管理各个聊天应用的连接
- `InboundWorker` 消费入站消息并调度会话
- `SessionManager`、`Tool.Registry`、`Cron`、`Subagent` 作为长期服务进程存在
- `Evolution` 和 `Surgeon` 负责热更新、版本保存与回滚

所以这个项目的技术选型不是背景信息，而是核心卖点之一。

## What Makes It Different

NexAgent 想解决的不是“怎么再包一层模型调用”，而是下面这组更接近真实运行的问题:

| 传统 Agent 原型 | NexAgent 想做的事 |
| --- | --- |
| 只在 CLI 里跑一轮任务 | 长期在线，进入聊天应用 |
| 主要依赖当前上下文窗口 | 有 sessions、memory、history 和检索 |
| 新能力主要靠改 prompt | 通过 tools、skills 和代码级进化扩展能力 |
| 出错后容易整轮中断 | 用 OTP 的监督树和服务进程维持系统稳定 |
| 部署后能力基本固定 | 允许运行中持续进化 |

## Install

### From source

环境要求:

- Elixir `~> 1.18`
- Erlang/OTP

安装依赖:

```bash
git clone https://github.com/gofenix/nex-agent.git
cd nex-agent
mix deps.get
```

## Quick Start

### 1. Initialize

```bash
mix nex.agent onboard
```

首次运行会创建默认配置和工作区:

```text
~/.nex/agent/
├── config.json
└── workspace/
    ├── AGENTS.md
    ├── SOUL.md
    ├── USER.md
    ├── skills/
    ├── sessions/
    └── memory/
        ├── MEMORY.md
        ├── HISTORY.md
        └── YYYY-MM-DD/log.md
```

### 2. Configure your model

最直接的方式是用 CLI 设置 provider、model 和 API key:

```bash
mix nex.agent config set provider openai
mix nex.agent config set model gpt-4o
mix nex.agent config set api_key openai sk-xxx
```

如果你使用 Ollama:

```bash
mix nex.agent config set provider ollama
mix nex.agent config set model llama3.1
```

默认支持的 provider:

- `anthropic`
- `openai`
- `openrouter`
- `ollama`

配置文件位于:

```text
~/.nex/agent/config.json
```

### 3. Chat

单轮调用:

```bash
mix nex.agent -m "hello"
```

交互模式:

```bash
mix nex.agent
```

### 4. Run the gateway

```bash
mix nex.agent gateway
```

查看状态:

```bash
mix nex.agent status
```

停止网关:

```bash
mix nex.agent gateway stop
```

## Chat Apps

NexAgent 不应该只待在 CLI 里。

它的目标是运行在你已经使用的聊天应用中，让 Agent 真正进入日常沟通和工作流。

当前代码中已经支持:

| Channel | What you need |
| --- | --- |
| Telegram | Bot Token |
| Feishu | App ID + App Secret |
| Discord | Bot Token |
| Slack | Bot Token + App-Level Token |
| DingTalk | App Key + App Secret |

### Telegram

推荐从 Telegram 开始，接入路径最直接。

1. 使用 `@BotFather` 创建机器人并获得 token
2. 配置 `config.json` 或使用 CLI 设置 Telegram
3. 启动网关

示例:

```bash
mix nex.agent config set telegram.enabled true
mix nex.agent config set telegram.token 123456:ABCDEF
mix nex.agent config set telegram.allow_from 10001,10002
mix nex.agent config set telegram.reply_to_message true
mix nex.agent gateway
```

其他聊天应用当前更适合直接编辑 `~/.nex/agent/config.json` 完成配置。

## Models

NexAgent 当前支持以下 provider:

- Anthropic
- OpenAI
- OpenRouter
- Ollama

如果你想快速开始，最简单的路径通常是:

- 云端模型: OpenAI 或 OpenRouter
- 本地模型: Ollama

模型调用由 `Runner` 统一调度，再按 provider 适配到对应实现。

## Tools and Skills

### Built-in tools

当前默认内置工具包括:

- `read`
- `write`
- `edit`
- `list_dir`
- `bash`
- `web_search`
- `web_fetch`
- `message`
- `memory_search`
- `cron`
- `spawn_task`
- `skill_list`
- `skill_create`
- `soul_update`
- `reflect`
- `evolve`

这套工具覆盖了文件操作、命令执行、外部信息获取、消息发送、记忆检索、调度和自我进化。

### Skills

除了工具，NexAgent 还有一套基于 Markdown 的技能系统。

技能的角色不是“再写一层 prompt”，而是把工作流沉淀成可复用模块。它可以用于:

- 封装工作流
- 标准化重复任务
- 让 Agent 自己创建可复用说明

技能文件位于 `workspace/skills/<name>/SKILL.md`，并以 `skill_<name>` 工具形式暴露给模型。

需要确定性代码能力时，应通过 tools 系统实现；Elixir 模块属于 tools，不属于 skills。

## Memory and Sessions

NexAgent 的会话不是临时对话上下文，而是带有持久化和记忆层的长期会话。

### Sessions

会话按 `channel:chat_id` 维护，例如:

- `telegram:123456`
- `discord:channel_id`

这意味着不同聊天入口天然隔离，不会把所有上下文混成一团。

同时，当前也支持基础控制命令:

- `/new`: 开始新会话
- `/stop`: 停止当前会话的活动任务

### Memory

记忆系统分成几层:

- `MEMORY.md`: 长期记忆
- `HISTORY.md`: 历史记录
- 每日日志 `YYYY-MM-DD/log.md`: 运行过程中的经验记录
- `Memory.Index`: BM25 检索索引

这套设计的目标很直接:

- 不让 Agent 每次都从零开始
- 不把所有东西都堆进 prompt
- 让长期偏好、历史记录和运行日志各自承担不同职责

## Self-Evolution

这是 NexAgent 最核心的能力之一。

它的进化不是单点发生，而是按层次展开。

### Soul

`SOUL.md` 用于调整 agent 的行为方式、性格和价值观。

### Memory

通过 `MEMORY.md`、`HISTORY.md` 和每日日志，agent 可以持续累积经验，而不是只记住当前会话窗口里的信息。

### Skills and tools

通过 `skill_create` 和 tools 系统，agent 可以不断扩展自己的能力边界。

### Code evolution

真正拉开差异的是源码级进化链路:

- `reflect`: 读取模块源码、版本历史和 diff
- `evolve`: 提交新的模块代码
- `Evolution`: 负责备份、校验、编译、加载和版本管理
- `Surgeon`: 负责升级流程、热替换和失败回滚

这让 NexAgent 不只是“可配置的 agent”，而是一个具备真实自修改能力的 agent 系统。

```mermaid
flowchart LR
    A["Reflect<br/>读取源码 / 历史 / diff"] --> B["Understand<br/>定位问题或机会"]
    B --> C["Evolve<br/>提交新代码"]
    C --> D["Evolution<br/>备份 / 校验 / 编译 / 加载"]
    D --> E["Surgeon<br/>热替换 / 回滚保护"]
    E --> F["Agent keeps running"]
```

## Automation

### Cron

NexAgent 内置 `cron` 工具来管理计划任务。

支持的操作包括:

- 新增任务
- 列出任务
- 启用 / 禁用任务
- 手动触发任务
- 查看状态

支持的调度方式包括:

- `every_seconds`
- `cron_expr`
- `at`

为了降低长期运行成本，cron 的执行方式也做了专门优化:

- 限制工具范围
- 减少历史上下文
- 跳过部分技能与记忆整理
- 与用户主会话隔离

### Subagent

`spawn_task` 可以派生后台子代理来执行独立任务。

它适合:

- 耗时任务
- 可拆分的子问题
- 不希望阻塞主会话的工作

子代理执行完成后，会把结果通过总线回送给主流程。

## Architecture

NexAgent 的结构不是一组松散脚本，而是一个分层的长期系统。

```mermaid
flowchart TB
    subgraph L1["Entry Layer"]
        A["Chat Apps"]
        B["Gateway"]
    end

    subgraph L2["Agent Layer"]
        C["InboundWorker"]
        D["Runner"]
    end

    subgraph L3["Capability Layer"]
        E["Sessions"]
        F["Memory + Memory.Index"]
        G["Tools + Tool.Registry"]
        H["Skills"]
    end

    subgraph L4["Background Layer"]
        I["Cron"]
        J["Subagent"]
    end

    subgraph L5["Evolution Layer"]
        K["Reflect + Evolve"]
        L["Evolution + Surgeon"]
    end

    A --> B --> C --> D
    D --> E
    D --> F
    D --> G
    D --> H
    D --> I
    D --> J
    D --> K --> L
```

如果换一种更接近系统分层的看法，可以把它理解成:

- **入口层**: Chat Apps + Gateway
- **Agent 层**: InboundWorker + Runner
- **能力层**: Tools + Skills + Memory + Sessions
- **后台层**: Cron + Subagent
- **进化层**: Reflect + Evolve + Evolution + Surgeon

对应到代码中的核心角色:

- `Gateway`: 管理各个聊天应用的连接进程
- `InboundWorker`: 路由入站消息
- `Runner`: 构建上下文并执行 agent loop
- `SessionManager`: 管理持久化会话
- `Memory` / `Memory.Index`: 管理长期记忆与检索
- `Tool.Registry`: 动态管理工具
- `Skills`: 加载和执行技能
- `Cron`: 管理计划任务
- `Subagent`: 管理后台子代理
- `Evolution` / `Surgeon`: 管理源码进化

这些组件由 OTP 监督树统一组织，而不是散落成一组脚本。

## Security

NexAgent 当前已经实现了一些基础安全边界:

- 文件访问限制在允许根目录内
- 路径穿越会被校验
- Shell 命令有白名单与危险模式拦截
- 聊天应用支持 `allow_from`
- cron 和 subagent 使用受限执行路径

它还远没到终局，但方向是明确的: 不是一个默认无限权力的本地 agent。

## Closing

如果用一句话概括:

> NexAgent 是一个基于 Elixir/OTP 构建、可长期运行并持续进化的 AI Agent。

它真正的差异点，不是又支持了一个 provider，也不是单纯多了几个工具，而是试图把下面这些能力放进同一个系统里:

- 长期在线运行
- 出现在聊天应用里
- 持久化会话与记忆
- 可扩展的工具和技能
- 定时任务与后台子代理
- 源码级自我进化
- OTP 驱动的容错与热更新

如果你关心的是 Agent 如何在真实环境中长期存在，而不是只在 demo 中完成一次任务，NexAgent 走的就是这条路线。
