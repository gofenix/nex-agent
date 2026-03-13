# 养了 OpenClaw 之后，我开始种自己的树

> OpenClaw 让更多人看到了 AI Agent 的未来。我在想：如果 Agent 要陪伴我 10 年，应该长什么样？

---

## 先说结论

**OpenClaw [31万 star](https://github.com/openclaw/openclaw)，实至名归。**

它证明了"个人 AI Agent"这个方向是对的，证明了普通用户愿意为"能动手干活的 AI"买单。作为一个关注 AI 很久的人，看到这只红色龙虾火遍全球，我是真心高兴的——这意味着 Agent 终于从小众走向大众了。

我自己也养了一只。使用过程中，我发现了一些有趣的问题，让我开始思考：**如果 Agent 不只是"工具"，而是需要 7×24 小时运行、越用越聪明的"伙伴"，技术架构会有什么不同？**

这个问题没有标准答案。OpenClaw 用 TypeScript/Node.js 证明了这个需求的普遍性，而我想用 Elixir/OTP 探索另一个可能性。

于是有了 [NexAgent](https://github.com/gofenix/nex-agent)。

**这不是要挑战 OpenClaw，而是想在"长期运行的 Agent"这个细分方向上做些实验。**

---

## 我的养虾经历

和很多人一样，我是在 Twitter 上看到 OpenClaw 的。

红色龙虾 logo，[31万 star](https://github.com/openclaw/openclaw)，"AI 数字员工"的概念——这不就是《钢铁侠》里的贾维斯吗？

我立马下载安装，配置 Telegram Bot，扔给它一个任务："每天早 8 点检查我的 GitHub Issues，把高优先级的发到飞书。"

**刚开始：真香**

- 早上醒来看到 Agent 已经分类好了 Issues
- 我在 Telegram 问"今天有什么 bug"，它记得昨天的上下文
- 感觉生活质量提升了 20%

**用了一阵子：有惊喜也有困惑**

- 功能真的很强大，视觉识别、工具调用都很流畅
- 但运行久了响应会变慢，从秒回变成等 3-5 秒
- 偶尔需要重启一下才能恢复
- 我以为是配置问题，查了很多文档

**后来：一个意外**

- 某天早上什么都没发生
- 看日志发现进程挂了，内存占用过高
- 重启后，它忘了这周积累的上下文
- 那一刻我有点沮丧：这个"记住我一切"的 AI，原来也有记忆边界

**再后来：我开始想另一个问题**

- 如果我不想只是"用"Agent，而是想"养"一个长期陪伴的 Agent 呢？
- 它需要 7×24 小时稳定在线
- 它需要越用越聪明，而不是每次重启都归零
- 它需要能自我进化，而不是等作者发新版本

这让我想到了另一个技术栈。

---

## 为什么考虑 Elixir/OTP

OpenClaw 用 TypeScript/Node.js 是非常正确的选择——这个栈降低了门槛，让 31 万人都能参与进来。这是开源项目成功的关键。

但我好奇的是：**如果目标是"永不停止的系统"，会不会有其他解法？**

这让我想起了 Elixir/OTP。不是为了炫技，而是因为 OTP（Open Telecom Platform）本来就是为电信系统设计的——那种必须 7×24 小时运行、不能崩、能热更新的系统。

| 场景 | Node.js 思路 | OTP 思路 |
|-----|-------------|---------|
| 进程管理 | 单进程 + 外部重启 | 监督树自动重启 |
| 内存隔离 | 同一进程空间 | 每个任务独立进程 |
| 热更新 | 重启服务 | 不停机热加载 |
| 错误恢复 | 人工介入 | 自动恢复 + 降级 |

这不是谁好谁坏的问题，是**不同场景下的不同取舍**。
- OpenClaw 选择低门槛，让更多人能用上 Agent
- NexAgent 选择高稳定，探索长期陪伴的可能性

---

## NexAgent 的核心实验

我用 Elixir 重写了 Agent 核心，做了几个有趣的实验：

### 实验 1：长期运行

我把 NexAgent 跑在本机上，持续使用了一段时间：

- **运行状态**：稳定，没有内存泄漏
- **响应速度**：保持流畅，没有明显变慢
- **进程管理**：工具崩溃时自动重启，主循环不受影响

不需要手动重启，OTP 的监督树机制确实让系统很省心。

### 实验 2：热更新（真实案例）

高德天气工具突然失效，API 返回权限错误。

Agent 自己诊断出问题：Key 绑定了 iOS 平台，但当前是服务器调用。然后它自动修改了代码，把 key 获取逻辑改为读取 Web 服务 Key。

4 分钟后，深圳天气查询成功。服务没有重启，会话保持连续。

**这是真实的运行截图：**
![Agent 自动修复高德天气工具](images/amap-weather-fix.png)

从诊断问题到生成修复代码，再到热加载验证，全程没有人工干预写代码。

### 实验 3：自我进化的能力

NexAgent 内置了代码自我改进的管道：

1. **Reflect**：查看任意模块的源码
2. **分析**：理解问题并生成修复方案  
3. **Upgrade**：提交代码变更，自动热加载

这意味着当工具逻辑需要调整时（比如 API 响应格式变化），Agent 可以自己查看源码、修改代码、完成热更新，无需人工介入重启服务。

这套机制已经跑通，真正的"全自动修复"场景还在探索中。

---

## 两种不同的"养"

养 OpenClaw 像养**龙虾**——
- 长得快，功能强大
- 体验震撼，让人兴奋
- 但需要经常关注状态，重启恢复

养 NexAgent 像种**树**——
- 长得慢，前期投入大
- 但一旦扎根，可以陪伴很多年
- 它会记住你的一切，越用越懂你

**你想养哪个？**

取决于你的需求：
- 如果你是想快速体验 AI Agent 的能力，**选 OpenClaw**
- 如果你需要 7×24 小时稳定运行的服务，**可以看看 NexAgent**
- 如果你希望 Agent 能自我进化、长期积累，**NexAgent 在探索这个方向**

---

## NexAgent 的技术亮点

### 1. 监督树：崩溃自动重启

```elixir
# lib/nex/agent/application.ex
children = [
  NexAgent.InfrastructureSupervisor,
  NexAgent.WorkerSupervisor,
  NexAgent.Gateway
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

如果基础设施崩溃，所有 Worker 联动重启；如果只是某个工具失败，只重启那个工具，不影响主 Agent。

### 2. 进程隔离：每个任务独立

```elixir
# lib/nex/agent/tool/registry.ex:181
Task.Supervisor.start_child(NexAgent.ToolTaskSupervisor, fn ->
  tool_module.execute(args)
end)
```

每个工具调用都在独立进程里，崩溃不影响主循环。

### 3. 热更新：不重启升级

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
    _ = rollback(module)  # 失败自动回滚
    {:error, to_error(reason)}
end
```

### 4. 双层记忆系统

- **MEMORY.md**：长期记忆（项目背景、用户偏好）
- **HISTORY.md**：可搜索的历史对话

并且支持**异步收敛**：当会话变长时，Agent 会在后台自动总结历史，提取关键信息写入长期记忆，不影响当前对话响应速度。

---

## 六层进化模型

NexAgent 的进化不是单点的，而是六个层次：

1. **SOUL**：Agent 的人格、价值观
2. **USER**：用户画像、协作方式
3. **MEMORY**：长期记忆、项目知识
4. **SKILL**：可复用的工作流
5. **TOOL**：具体的工具能力
6. **CODE**：源代码级别的自我改进

每一层都在积累，每一层都可以独立进化。

---

## 快速开始

如果你好奇 NexAgent 长什么样：

```bash
# 1. 安装 Elixir（~> 1.18）
# 2. 克隆仓库
git clone https://github.com/gofenix/nex-agent.git
cd nex-agent
mix deps.get

# 3. 初始化
mix nex.agent onboard

# 4. 配置config文件

# 5. 启动网关
mix nex.agent gateway
```

更详细的文档：[GitHub 仓库](https://github.com/gofenix/nex-agent)

---

## 写在最后

OpenClaw 让更多人看到了 AI Agent 的可能性。这是整个行业的进步。

NexAgent 只是想在一个更细分的方向上探索：**如果 Agent 需要长期陪伴，技术架构会有什么不同？**

[31万人在养龙虾](https://github.com/openclaw/openclaw)，体验"有 AI 是什么"。

我在种树，等待它长成参天大树的那一天。

**两种不同的路径，同样的目标：让 AI 真正融入生活。**

---

**相关链接**：
- NexAgent GitHub: https://github.com/gofenix/nex-agent
- OpenClaw GitHub: https://github.com/openclaw/openclaw

---

*最后更新：2026-03-13*
