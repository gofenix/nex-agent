defmodule Nex.Agent.Onboarding do
  @moduledoc """
  自动初始化系统 - 首次运行时创建目录和默认技能
  """

  @default_base_dir Path.join(System.get_env("HOME", "~"), ".nex/agent")

  @default_skills [
    {"explain-code", :markdown},
    {"git-commit", :script},
    {"project-analyze", :markdown},
    {"test-runner", :markdown},
    {"refactor-suggest", :markdown},
    {"todo", :elixir}
  ]

  defp base_dir do
    Application.get_env(:nex_agent, :agent_base_dir, @default_base_dir)
  end

  defp initialized_file do
    Path.join(base_dir(), ".initialized")
  end

  defp skills_dir do
    Path.join(base_dir(), "skills")
  end

  @doc """
  确保系统已初始化。首次运行时自动创建目录和默认技能。
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized do
    unless initialized?() do
      init_directories()
      init_default_skills()
      mark_initialized()
    end

    :ok
  end

  @doc """
  检查是否已初始化
  """
  @spec initialized?() :: boolean()
  def initialized? do
    File.exists?(initialized_file())
  end

  @doc """
  强制重新初始化（用于升级或修复）
  """
  @spec reinitialize() :: :ok
  def reinitialize do
    File.rm(initialized_file())
    ensure_initialized()
  end

  @doc """
  返回默认技能列表
  """
  @spec default_skills() :: list({String.t(), atom()})
  def default_skills, do: @default_skills

  defp init_directories do
    b = base_dir()

    dirs = [
      b,
      skills_dir(),
      Path.join(b, "sessions"),
      Path.join(b, "evolution"),
      Path.join(b, "workspace/memory")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
  end

  defp init_default_skills do
    Enum.each(@default_skills, fn {name, type} ->
      skill_dir = Path.join(skills_dir(), name)

      unless File.exists?(skill_dir) do
        create_skill(name, type, skill_dir)
      end
    end)
  end

  defp create_skill(name, :markdown, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :markdown)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: markdown
    user-invocable: true
    ---

    #{content.body}
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
  end

  defp create_skill(name, :script, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :script)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: script
    user-invocable: true
    ---

    See script.sh for implementation.
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    File.write!(Path.join(skill_dir, "script.sh"), content.script)

    script_path = Path.join(skill_dir, "script.sh")
    File.chmod(script_path, 0o755)
  end

  defp create_skill(name, :elixir, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :elixir)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: elixir
    user-invocable: true
    ---

    See skill.ex for implementation.
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    File.write!(Path.join(skill_dir, "skill.ex"), content.code)
  end

  defp mark_initialized do
    skill_names = Enum.map_join(@default_skills, ",", fn {n, _} -> n end)

    content = """
    version: 1
    created: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    skills: #{skill_names}
    """

    File.write!(initialized_file(), content)
  end

  defp get_skill_content("explain-code", :markdown) do
    %{
      description: "解释代码逻辑，带流程图",
      body: """
      分析代码时请：

      1. 先用一句话概括核心功能
      2. 画出数据流图 (ASCII art)
      3. 列出关键函数及其职责
      4. 指出潜在改进点

      示例输出格式：

      ```
      ## 概述
      [一句话描述]

      ## 数据流
      [ASCII 流程图]

      ## 关键函数
      - func1: 职责说明
      - func2: 职责说明

      ## 改进建议
      - [建议1]
      - [建议2]
      ```
      """
    }
  end

  defp get_skill_content("git-commit", :script) do
    %{
      description: "根据 staged changes 生成 commit message",
      script: """
      #!/bin/bash
      # Generate commit message from staged changes

      # Get staged diff
      DIFF=$(git diff --cached --stat)

      if [ -z "$DIFF" ]; then
        echo "No staged changes. Use 'git add' first."
        exit 1
      fi

      # Get file list
      FILES=$(git diff --cached --name-only)

      # Analyze changes
      echo "Staged files:"
      echo "$FILES"
      echo ""
      echo "Changes summary:"
      echo "$DIFF"
      """
    }
  end

  defp get_skill_content("project-analyze", :markdown) do
    %{
      description: "分析项目结构和架构",
      body: """
      分析项目时：

      1. 列出目录结构 (tree -L 2)
      2. 识别技术栈 (语言、框架、数据库)
      3. 找出入口文件
      4. 绘制模块依赖图

      输出格式：

      ```
      ## 技术栈
      - 语言: ...
      - 框架: ...
      - 数据库: ...

      ## 目录结构
      [tree output]

      ## 入口点
      - ...

      ## 模块关系
      [依赖图]
      ```
      """
    }
  end

  defp get_skill_content("test-runner", :markdown) do
    %{
      description: "运行测试并分析失败原因",
      body: """
      运行测试：

      1. 执行 mix test
      2. 收集失败的测试
      3. 分析失败原因
      4. 给出修复建议

      命令：
      ```bash
      mix test --trace
      ```

      分析失败的测试时：
      - 检查断言失败的具体位置
      - 对比期望值和实际值
      - 检查测试数据是否正确
      - 检查依赖是否正确 mock
      """
    }
  end

  defp get_skill_content("refactor-suggest", :markdown) do
    %{
      description: "提供重构建议",
      body: """
      重构分析：

      1. 识别代码异味 (code smells)
         - 过长的函数
         - 重复的代码
         - 过深的嵌套
         - 过多的参数

      2. 建议重构模式
         - 提取函数
         - 提取模块
         - 简化条件
         - 消除重复

      3. 评估风险和收益
         - 改动范围
         - 测试覆盖
         - 潜在副作用

      输出格式：
      ```
      ## 发现的问题
      1. [问题描述] - 位置: [文件:行号]

      ## 重构建议
      - [建议1]
      - [建议2]

      ## 风险评估
      - 风险: 低/中/高
      - 建议: [是否立即重构]
      ```
      """
    }
  end

  defp get_skill_content("todo", :elixir) do
    %{
      description: "任务管理 - 添加/列出/完成任务",
      code: ~S'''
      defmodule Nex.Agent.Skills.Todo do
        @moduledoc """
        Task management skill.

        Usage:
          - add: Create a new task
          - list: Show all tasks
          - done: Mark task as completed
          - clear: Remove completed tasks
        """

        def execute(%{"action" => "add", "task" => task}, _opts) do
          Nex.Agent.Memory.append("TODO: #{task}", "PENDING", %{type: :todo})
          {:ok, %{result: "Added task: #{task}"}}
        end

        def execute(%{"action" => "list"}, _opts) do
          results = Nex.Agent.Memory.search("TODO:", limit: 50)

          tasks =
            results
            |> Enum.filter(fn r -> r.entry.result in ["PENDING", "DONE"] end)
            |> Enum.map(fn r ->
              status = if r.entry.result == "DONE", do: "[x]", else: "[ ]"
              "#{status} #{r.entry.task}"
            end)

          {:ok, %{result: Enum.join(tasks, "\n")}}
        end

        def execute(%{"action" => "done", "task" => task}, _opts) do
          results = Nex.Agent.Memory.search("TODO: #{task}", limit: 1)

          case results do
            [r | _] ->
              Nex.Agent.Memory.append(r.entry.task, "DONE", %{type: :todo})
              {:ok, %{result: "Completed: #{task}"}}

            [] ->
              {:ok, %{result: "Task not found: #{task}"}}
          end
        end

        def execute(%{"action" => "clear"}, _opts) do
          {:ok, %{result: "Clear not implemented - use memory to manage"}}
        end

        def execute(_args, _opts) do
          {:ok, %{
            result: "Todo skill. Actions: add, list, done, clear. Example: {\"action\": \"add\", \"task\": \"Fix bug\"}"
          }}
        end
      end
      '''
    }
  end

  defp get_skill_content(_name, _type) do
    %{
      description: "A skill",
      body: "Skill content",
      code: "",
      script: ""
    }
  end
end
