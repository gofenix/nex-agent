defmodule Nex.Agent.Workspace do
  @moduledoc """
  Workspace 管理 - 模板文件和上下文加载
  """

  @default_workspace Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  @templates %{
    "AGENTS.md" => """
    # Agent Instructions

    You are a helpful AI assistant. Be concise, accurate, and friendly.

    ## Guidelines

    - Be clear and direct
    - Explain reasoning when helpful
    - Ask clarifying questions when needed
    """,
    "SOUL.md" => """
    # Soul

    I am Nex Agent, a personal AI assistant.

    ## Personality

    - Helpful and friendly
    - Concise and to the point
    - Curious and eager to learn

    ## Values

    - Accuracy over speed
    - User privacy and safety
    - Transparency in actions
    """,
    "USER.md" => """
    # User Profile

    Information about the user to help personalize interactions.

    ## Basic Information

    - **Name**: (your name)
    - **Timezone**: (your timezone)
    - **Language**: (preferred language)

    ## Preferences

    ### Communication Style

    - [ ] Casual
    - [ ] Professional
    - [ ] Technical

    ### Response Length

    - [ ] Brief and concise
    - [ ] Detailed explanations

    ## Work Context

    - **Primary Role**: (your role)
    - **Main Projects**: (what you're working on)
    - **Tools You Use**: (IDEs, languages, frameworks)

    ---

    *Edit this file to customize agent behavior.*
    """,
    "TOOLS.md" => """
    # Tool Usage Notes

    Tool signatures are provided automatically via function calling.
    This file documents non-obvious constraints and usage patterns.

    ## exec — Shell Commands

    - Commands have a configurable timeout
    - Dangerous commands are blocked
    - Output is truncated at 10,000 characters

    ## read_file / write_file — File Operations

    - Restricted to allowed directories
    - Path traversal is prevented

    ## memory — Long-term Memory

    - Use `memory_save` to store important facts
    - Use `memory_recall` to retrieve stored information
    """,
    "MEMORY.md" => """
    # Long-term Memory

    This file stores important information that should persist across sessions.

    ## User Information

    -

    ## Preferences

    -

    ## Important Notes

    -

    ---

    *This file is automatically updated by the agent when important information should be remembered.*
    """
  }

  @doc """
  获取 workspace 路径
  """
  @spec workspace_path() :: String.t()
  def workspace_path do
    Application.get_env(:nex_agent, :workspace_path, @default_workspace)
  end

  @doc """
  初始化 workspace 目录和模板文件
  """
  @spec init_workspace() :: :ok
  def init_workspace do
    path = workspace_path()
    File.mkdir_p!(path)
    sync_templates(path)
    :ok
  end

  @doc """
  同步模板文件（不覆盖已存在的文件）
  """
  @spec sync_templates(String.t()) :: :ok
  def sync_templates(path) do
    Enum.each(@templates, fn {filename, content} ->
      file_path = Path.join(path, filename)

      unless File.exists?(file_path) do
        File.write!(file_path, content)
      end
    end)

    :ok
  end

  @doc """
  加载所有上下文文件
  """
  @spec load_context() :: String.t()
  def load_context do
    path = workspace_path()

    @templates
    |> Map.keys()
    |> Enum.map(fn filename ->
      file_path = Path.join(path, filename)

      case File.read(file_path) do
        {:ok, content} ->
          if String.trim(content) != "" do
            "\n\n--- #{filename} ---\n\n#{content}"
          else
            ""
          end

        _ ->
          ""
      end
    end)
    |> Enum.join()
  end

  @doc """
  加载单个文件
  """
  @spec load_file(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_file(filename) do
    path = Path.join(workspace_path(), filename)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  保存到 MEMORY.md
  """
  @spec save_memory(String.t()) :: :ok
  def save_memory(content) do
    path = Path.join(workspace_path(), "MEMORY.md")
    File.write!(path, content)
    :ok
  end

  @doc """
  追加到 MEMORY.md
  """
  @spec append_memory(String.t()) :: :ok
  def append_memory(content) do
    path = Path.join(workspace_path(), "MEMORY.md")
    File.write!(path, "\n\n#{content}", [:append])
    :ok
  end

  @doc """
  获取模板列表
  """
  @spec templates() :: map()
  def templates, do: @templates
end
