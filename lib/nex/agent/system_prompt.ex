defmodule Nex.Agent.SystemPrompt do
  def build(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    """
    #{date_header()}
    #{project_context(cwd)}
    #{skill_forging()}
    #{tool_descriptions()}
    #{guidelines()}
    """
  end

  defp date_header do
    now = DateTime.utc_now()
    "Date: #{now.year}-#{pad(now.month)}-#{pad(now.day)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp project_context(cwd) do
    agents_md = Path.join(cwd, "AGENTS.md")
    system_md = Path.join(cwd, "SYSTEM.md")

    ctx =
      []
      |> read_if_exists(agents_md, "## Project Instructions")
      |> read_if_exists(system_md, "## System Instructions")

    if ctx == [] do
      ""
    else
      Enum.join(ctx, "\n\n")
    end
  end

  defp read_if_exists(acc, path, header) do
    if File.exists?(path) do
      content = File.read!(path)
      acc ++ ["#{header}\n\n#{content}\n"]
    else
      acc
    end
  end

  defp skill_forging do
    """
    ## Skill 锻造

    如果你发现某个任务会重复出现（每天、每周、定期），你应该自动创建一个 Skill 来自动化这个任务。

    **什么时候应该锻造 Skill：**
    - 任务需要重复执行（如每天整理新闻、每周汇总）
    - 任务涉及多个步骤（抓取 → 分析 → 整理）
    - 你发现自己经常在做同样的事情

    **锻造 Skill 的方法：**
    使用 skill_create 工具来创建新 Skill：

    ```
    skill_create({
      name: "hn_digest",
      description: "抓取并分析 Hacker News 热门文章",
      type: "elixir",  // 或 "script", "mcp", "markdown"
      code: "Elixir 代码或脚本内容",
      parameters: {
        "topic": {"type": "string", "description": "感兴趣的话题"}
      }
    })
    ```

    **Skill 类型：**
    - `elixir`: Elixir 代码，使用 Evolution 热加载，最灵活
    - `script`: Shell/Python 脚本，简单直接
    - `mcp`: MCP 服务器配置
    - `markdown`: 纯文本 prompt（现有方式）

    **数据存储：**
    所有 Skills 的数据都存储在 Memory 里（使用 Memory.append），
    这样不同 Skills 的数据可以自然流通。

    例如：
    - hn_digest skill 抓取新闻 → 存入 Memory
    - todo skill 读取 Memory 中的新闻 → 生成待办
    """
  end

  defp tool_descriptions do
    """
    ## Tools

    read: Read file contents
    bash: Execute bash commands (ls, grep, find, etc.)
    edit: Make surgical edits to files (find exact text and replace)
    write: Create or overwrite files

    ## Skill Management

    skill_create: Create a new skill for automating repetitive tasks
    skill_list: List all available skills
    skill_execute: Execute a skill with arguments
    """
  end

  defp guidelines do
    """
    ## Guidelines

    - Use the least invasive tool possible
    - Prefer read over edit, edit over write
    - Always verify after writing/editing
    - Keep changes focused and minimal
    - If you find yourself doing the same thing repeatedly, create a skill!
    """
  end
end
