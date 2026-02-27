# Nex Agent 使用指南

## 快速开始

### 1. 启动 Agent

```elixir
# 创建一个 session
{:ok, session} = Nex.Agent.Session.create(project_id: "my-project")

# 运行 agent
{:ok, result, session} = Nex.Agent.Runner.run(
  session,
  "帮我创建一个 hello.ex 文件，内容是 IO.puts(\"Hello World\")"
)
```

### 2. 使用内置工具

Agent 可以直接使用这些工具：

```elixir
# 读取文件
Agent: "read the file mix.exs"

# 写入文件  
Agent: "write to hello.txt with content 'Hello World'"

# 编辑文件
Agent: "edit mix.exs, replace 'defp' with 'def'"

# 执行命令
Agent: "run mix test"
```

### 3. 使用 Memory

```elixir
# 保存到记忆
Nex.Agent.Memory.append("Fixed login bug", "SUCCESS", %{issue: "123"})

# 搜索记忆
results = Nex.Agent.Memory.search("login bug")
```

Agent 也可以直接调用：
```
Agent: "记住这个教训：always validate input"
Agent: "搜索之前关于数据库的记忆"
```

### 4. 使用 Skills

创建 `~/.nex/agent/skills/deploy/SKILL.md`:

```yaml
---
name: deploy
description: Deploy the application to production
disable-model-invocation: true
---

Deploy the application to production:

1. Run tests: mix test
2. Build: mix release
3. Deploy to host
```

然后使用：
```
Agent: /deploy production
```

### 5. 使用 MCP

```elixir
# 发现可用的 MCP servers
servers = Nex.Agent.MCP.Discovery.scan()

# 启动一个 MCP server
{:ok, server_id} = Nex.Agent.MCP.ServerManager.start("filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/xxx/data"]
)

# 调用 MCP 工具
{:ok, result} = Nex.Agent.MCP.ServerManager.call_tool(server_id, "read_file", %{path: "..."})
```

Agent 也可以直接调用：
```
Agent: "发现可用的 MCP servers"
Agent: "启动 filesystem server"
Agent: "用 MCP 读取 /Users/xxx/data/file.txt"
```

### 6. 代码进化（核心功能！）

Agent 可以修改自己的代码：

```
Agent: "修改 Nex.Agent.Runner，增加日志功能"
Agent: "查看 Nex.Agent.Runner 的版本历史"
Agent: "回滚到上一个版本"
```

或者直接调用：

```elixir
# 修改代码
{:ok, version} = Nex.Agent.Evolution.upgrade_module(
  Nex.Agent.Runner,
  "def run(...) do\n  IO.puts(\"Modified!\")\n  # ...\nend"
)

# 回滚
:ok = Nex.Agent.Evolution.rollback(Nex.Agent.Runner)

# 查看版本
versions = Nex.Agent.Evolution.list_versions(Nex.Agent.Runner)
```

### 7. 反思

```
Agent: "反思一下刚才的执行，有什么可以改进的？"
Agent: "分析一下最近的错误模式"
```

---

## 配置

### MCP 配置

创建 `~/.nex/agent/mcp.json`:

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/xxx/data"]
    },
    "github": {
      "command": "/path/to/mcp-server-github",
      "env": {
        "GITHUB_TOKEN": "xxx"
      }
    }
  }
}
```

### 环境变量

```bash
export ANTHROPIC_API_KEY="sk-..."
export OPENAI_API_KEY="sk-..."
```

---

## 完整示例

```elixir
defmodule MyAgent do
  def run(prompt) do
    # 1. 创建 session
    {:ok, session} = Nex.Agent.Session.create(project_id: "demo")
    
    # 2. 加载 skills
    :ok = Nex.Agent.Skills.load()
    
    # 3. 运行 agent
    case Nex.Agent.Runner.run(session, prompt) do
      {:ok, result, session} ->
        IO.puts("Result: #{result}")
        
        # 4. 保存到记忆
        Nex.Agent.Memory.append(prompt, "SUCCESS", %{})
        
        {:ok, result}
        
      {:error, reason, _session} ->
        IO.puts("Error: #{reason}")
        {:error, reason}
    end
  end
end

# 使用
MyAgent.run("创建一个计数器模块")
```
