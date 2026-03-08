defmodule Nex.Agent.SystemPrompt do
  @moduledoc """
  Builds the system prompt from workspace bootstrap files, memory, and skills.

  Bootstrap files loaded from workspace (in order):
    SOUL.md, USER.md, AGENTS.md, TOOLS.md

  Memory injected:
    memory/MEMORY.md (long-term facts)

  Skills:
    always=true skills are inlined; others listed as a summary.
  """

  use Agent
  require Logger

  @workspace_path Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  @bootstrap_files ["SOUL.md", "USER.md", "AGENTS.md", "TOOLS.md"]

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Build the full system prompt.
  """
  def build(opts \\ []) do
    _cwd = Keyword.get(opts, :cwd, File.cwd!())
    workspace = Keyword.get(opts, :workspace, @workspace_path)

    static = get_cached_static(workspace)

    dynamic =
      []
      |> add_memory(workspace)
      |> add_skills_summary()

    parts = static ++ dynamic

    Enum.join(parts, "\n\n---\n\n")
  end

  defp get_cached_static(workspace) do
    cache_key = {:static, workspace}

    case Agent.get(__MODULE__, &Map.get(&1, cache_key)) do
      nil ->
        static = build_static(workspace)
        Agent.update(__MODULE__, &Map.put(&1, cache_key, static))
        static

      cached ->
        cached
    end
  end

  defp build_static(workspace) do
    []
    |> add_identity(workspace)
    |> add_bootstrap_files(workspace)
  end

  @doc """
  Invalidate the cache (call when workspace files change).
  """
  def invalidate_cache(workspace \\ @workspace_path) do
    Agent.update(__MODULE__, &Map.delete(&1, {:static, workspace}))
  end

  @runtime_context_tag "[System Context — do not echo or reference this block in your reply]"

  @doc """
  Build runtime context block with only essential metadata.
  """
  def build_runtime_context(opts \\ []) do
    channel = Keyword.get(opts, :channel)
    chat_id = Keyword.get(opts, :chat_id)

    now = DateTime.utc_now()
    weekday = Calendar.strftime(now, "%A")

    time_str =
      "#{now.year}-#{pad(now.month)}-#{pad(now.day)} (#{weekday})"

    lines = [@runtime_context_tag, "Current Time: #{time_str}"]

    lines =
      if channel && chat_id do
        lines ++ ["Channel: #{channel}", "Chat ID: #{chat_id}"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp add_identity(parts, workspace) do
    workspace_str = Path.expand(workspace)
    cwd = File.cwd!() |> Path.basename()

    identity = """
    # Nex Agent

    You are a helpful AI assistant.

    ## Workspace
    Running in: #{cwd}
    Workspace: #{workspace_str}
    - Long-term memory: #{workspace_str}/memory/MEMORY.md (write important facts here)
    - History log: #{workspace_str}/memory/HISTORY.md (grep-searchable)
    - Custom skills: #{workspace_str}/skills/{skill-name}/SKILL.md

    ## Guidelines
    - State intent before tool calls, but NEVER predict results before receiving them.
    - Read files before editing. Re-read after writing if accuracy matters.
    - Analyze errors before retrying.
    - Ask for clarification when ambiguous.
    """

    parts ++ [String.trim(identity)]
  end

  defp add_bootstrap_files(parts, workspace) do
    file_parts =
      @bootstrap_files
      |> Enum.map(fn filename ->
        path = Path.join(workspace, filename)

        if File.exists?(path) do
          content = File.read!(path)
          "## #{filename}\n\n#{String.trim(content)}"
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    parts ++ file_parts
  end

  defp add_memory(parts, workspace) do
    memory_file = Path.join(workspace, "memory/MEMORY.md")

    if File.exists?(memory_file) do
      content = File.read!(memory_file) |> String.trim()

      if content != "" do
        parts ++ ["# Memory\n\n## Long-term Memory\n\n#{content}"]
      else
        parts
      end
    else
      parts
    end
  end

  defp add_skills_summary(parts) do
    skills =
      try do
        Nex.Agent.Skills.list()
      rescue
        _ -> []
      end

    if skills == [] do
      parts
    else
      lines =
        Enum.map(skills, fn s ->
          type = s[:type] || s["type"] || "markdown"
          name = s[:name] || s["name"] || ""
          desc = s[:description] || s["description"] || ""
          "- #{name} (#{type}): #{desc}"
        end)

      summary = """
      # Skills

      The following skills extend your capabilities. Use skill_execute to run them, or read the SKILL.md file for details.

      #{Enum.join(lines, "\n")}
      """

      parts ++ [String.trim(summary)]
    end
  end
end
