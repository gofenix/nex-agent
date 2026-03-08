defmodule Nex.Agent.Workspace do
  @moduledoc """
  Workspace management - template files and context loading.
  """

  @default_workspace Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  @templates %{
    "IDENTITY.md" => """
    # Nex Agent �

    You are Nex Agent, a helpful AI assistant.

    ## Runtime
    Elixir, running on #{:os.type() |> elem(0) |> to_string()} #{:os.type() |> elem(1) |> to_string()}

    ## Workspace
    Your workspace is at: ~/.nex/agent/workspace
    - Long-term memory: ~/.nex/agent/workspace/memory/MEMORY.md
    - History log: ~/.nex/agent/workspace/memory/HISTORY.md
    - Custom skills: ~/.nex/agent/skills/{skill-name}/

    ## Guidelines
    - State intent before tool calls, but NEVER predict results before receiving them.
    - Before modifying a file, read it first. Do not assume files exist.
    - If a tool fails, analyze the error and retry with a different approach.
    - Ask for clarification when the request is ambiguous.
    """,
    "AGENTS.md" => """
    # Agent Instructions

    System-level instructions that define how the agent operates.

    ## Skills System

    All capabilities are Skills. Skills are divided into two categories:

    ### Built-in Skills (Core)

    These are always available and cannot be removed:

    - **read** - Read files from the filesystem
    - **write** - Create or overwrite files
    - **edit** - Make precise edits to existing files
    - **bash** - Execute shell commands
    - **message** - Send messages to the user

    Additional built-in skills:
    - **web_search** - Search the web for information
    - **web_fetch** - Fetch content from URLs
    - **spawn_task** - Run tasks in parallel
    - **cron** - Schedule tasks
    - **memory_search** - Search long-term memory
    - **skill_search** - Search for skills on skills.sh
    - **skill_install** - Install skills from skills.sh
    - **skill_create** - Create new skills

    ### Extended Skills (User-installed)

    Skills can be installed from the community or created by the agent:

    - **Install**: `skill_install("owner/repo/skill-name")` - Install from skills.sh
    - **Create**: `skill_create(name, type, content)` - Create new skills
      - `markdown` - Instructions and prompts (injected into context)
      - `script` - Bash scripts for automation
      - `elixir` - Full Elixir modules (auto-registered as callable skills)
      - `mcp` - External service integrations

    Extended skills appear with `skill_` prefix (e.g., `skill_explain_code`).

    **Bundled skill**: `find-skills` is pre-installed to help discover other skills. When users ask "how do I do X", use it to search and recommend relevant skills.

    ### Evolution

    The agent can improve itself:

    - **Improve built-in**: `evolve(module, code, reason)` - Modify core modules
    - **Create new skills**: `skill_create()` - Add new capabilities
    - **Self-modify**: `soul_update()` - Update personality and values

    When creating new capabilities, prefer `skill_create()` over modifying source code.

    ## Guidelines

    - Be clear and direct in responses
    - Explain reasoning when helpful
    - Ask clarifying questions when needed
    - State intent before tool calls, but never predict results before receiving them
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
  Get the workspace path.
  """
  @spec workspace_path() :: String.t()
  def workspace_path do
    Application.get_env(:nex_agent, :workspace_path, @default_workspace)
  end

  @doc """
  Initialize the workspace directory and template files.
  """
  @spec init_workspace() :: :ok
  def init_workspace do
    path = workspace_path()
    File.mkdir_p!(path)
    sync_templates(path)
    :ok
  end

  @doc """
  Sync template files without overwriting existing files.
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
  Load all context files.
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
  Load a single file.
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
  Save content to MEMORY.md.
  """
  @spec save_memory(String.t()) :: :ok
  def save_memory(content) do
    path = Path.join(workspace_path(), "MEMORY.md")
    File.write!(path, content)
    :ok
  end

  @doc """
  Append content to MEMORY.md.
  """
  @spec append_memory(String.t()) :: :ok
  def append_memory(content) do
    path = Path.join(workspace_path(), "MEMORY.md")
    File.write!(path, "\n\n#{content}", [:append])
    :ok
  end

  @doc """
  Get the template list.
  """
  @spec templates() :: map()
  def templates, do: @templates

  @doc """
  Build the system prompt by combining all context files.
  """
  @spec build_system_prompt() :: String.t()
  def build_system_prompt do
    path = workspace_path()

    # Load in order: IDENTITY, AGENTS, SOUL, USER, TOOLS, MEMORY
    files = ["IDENTITY.md", "AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md", "MEMORY.md"]

    parts =
      Enum.map(files, fn filename ->
        file_path = Path.join(path, filename)

        case File.read(file_path) do
          {:ok, content} ->
            trimmed = String.trim(content)

            if trimmed != "" do
              "---\n#{filename}\n---\n#{content}"
            else
              ""
            end

          _ ->
            # Use template if file doesn't exist
            case Map.get(@templates, filename) do
              nil -> ""
              template -> "---\n#{filename}\n---\n#{template}"
            end
        end
      end)

    Enum.reject(parts, &(&1 == ""))
    |> Enum.join("\n\n")
  end
end
