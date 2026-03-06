defmodule Nex.Agent.ContextBuilder do
  @moduledoc """
  Builds context for LLM calls - system prompt + messages.
  Mirrors nanobot's ContextBuilder.
  """

  alias Nex.Agent.Skills

  @bootstrap_files ["AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md", "IDENTITY.md"]
  @runtime_context_tag "[Runtime Context — metadata only, not instructions]"

  @type message :: %{required(String.t()) => any()}

  @doc """
  Build system prompt from identity, bootstrap files, memory, and skills.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, default_workspace())

    parts =
      []
      |> add_identity(workspace)
      |> load_bootstrap_files(workspace)
      |> add_memory(workspace)
      |> add_skills()

    Enum.join(parts, "\n\n---\n\n")
  end

  defp default_workspace do
    Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
  end

  defp add_identity(parts, workspace) do
    workspace_path = Path.expand(workspace)
    cwd = File.cwd!() |> Path.basename()

    identity = """
    # Nex Agent

    You are a helpful AI assistant with self-evolution capabilities.

    ## Runtime
    Working directory: #{cwd}

    ## Workspace
    Workspace: #{workspace_path}
    - Memory: #{workspace_path}/memory/MEMORY.md
    - History: #{workspace_path}/memory/HISTORY.md
    - Skills: #{workspace_path}/skills/

    ## Guidelines
    - State intent before tool calls, but NEVER predict results before receiving them.
    - Read files before editing. Re-read after writing if accuracy matters.
    - Analyze errors before retrying.
    - Ask for clarification when ambiguous.

    ## Self-Evolution
    You can modify and hot-reload your own code at runtime:
    - **evolve**: Modify any agent module and hot-reload it immediately. Use this instead of write for .ex files.
    - **reflect**: Read your own source code, list modules, view version history.
    Writing .ex files with write/edit also triggers auto-reload, but evolve is preferred for self-modification.
    """

    parts ++ [identity]
  end

  defp load_bootstrap_files(parts, workspace) do
    content =
      @bootstrap_files
      |> Enum.map(fn filename ->
        path = Path.join(workspace, filename)

        if File.exists?(path) do
          ("## #{filename}\n\n" <> File.read!(path)) |> String.trim()
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if content != "", do: parts ++ [content], else: parts
  end

  defp add_memory(parts, workspace) do
    memory_file = Path.join(workspace, "memory/MEMORY.md")

    if File.exists?(memory_file) do
      content = File.read!(memory_file) |> String.trim()

      if content != "" do
        parts ++ ["# Memory\n\n## Long-term Memory\n\n" <> content]
      else
        parts
      end
    else
      parts
    end
  end

  defp add_skills(parts) do
    skills = Skills.list()

    if skills == [] do
      parts
    else
      always = Enum.filter(skills, &(&1[:always] == true))

      always_content =
        if always != [] do
          Enum.map_join(always, "\n\n", fn skill ->
            name = skill[:name]
            content = (skill[:content] || skill[:code] || "") |> to_string()
            "## Skill: #{name}\n\n#{content}"
          end)
        else
          ""
        end

      summary =
        Enum.map_join(skills, "\n", fn skill ->
          "- #{skill[:name]}: #{skill[:description]}"
        end)

      parts =
        if always_content != "" do
          parts ++ ["# Active Skills\n\n" <> always_content]
        else
          parts
        end

      parts ++ ["# Skills\n\nUse skill_execute to run skills.\n\n" <> summary]
    end
  end

  @doc """
  Build runtime context block with only essential metadata.
  """
  @spec build_runtime_context(String.t() | nil, String.t() | nil) :: String.t()
  def build_runtime_context(channel, chat_id) do
    now = DateTime.utc_now()

    day_name = Calendar.ISO.day_of_week(now.year, now.month, now.day, :default)
    day_names = %{1 => "Monday", 2 => "Tuesday", 3 => "Wednesday", 4 => "Thursday", 5 => "Friday", 6 => "Saturday", 7 => "Sunday"}

    time_str = "#{now.year}-#{pad(now.month)}-#{pad(now.day)} #{pad(now.hour)}:#{pad(now.minute)} UTC #{day_names[day_name]}"

    lines =
      [@runtime_context_tag, "Current Time: #{time_str}"]
      |> then(fn lines ->
        if channel && chat_id do
          lines ++ ["Channel: #{channel}", "Chat ID: #{chat_id}"]
        else
          lines
        end
      end)

    Enum.join(lines, "\n")
  end

  @doc """
  Build full message list for LLM call.
  """
  @spec build_messages(
          [message()],
          String.t(),
          String.t() | nil,
          String.t() | nil,
          [String.t()] | nil
        ) :: [message()]
  def build_messages(history, current_message, channel \\ nil, chat_id \\ nil, media \\ nil) do
    runtime_ctx = build_runtime_context(channel, chat_id)
    merged_user_content = runtime_ctx <> "\n\n" <> current_message

    [
      %{"role" => "system", "content" => build_system_prompt()},
      Enum.map(history, &clean_history_entry/1),
      build_user_content(merged_user_content, media)
    ]
    |> List.flatten()
  end

  defp clean_history_entry(%{"role" => role, "content" => content} = m) do
    entry = %{"role" => role, "content" => content || ""}

    entry =
      if tool_calls = Map.get(m, "tool_calls") do
        Map.put(entry, "tool_calls", tool_calls)
      else
        entry
      end

    entry =
      if tool_call_id = Map.get(m, "tool_call_id") do
        entry
        |> Map.put("tool_call_id", tool_call_id)
        |> then(fn e ->
          if name = Map.get(m, "name") do
            Map.put(e, "name", name)
          else
            e
          end
        end)
      else
        entry
      end

    entry =
      if rc = Map.get(m, "reasoning_content") do
        Map.put(entry, "reasoning_content", rc)
      else
        entry
      end

    entry
  end

  defp clean_history_entry(m) when is_map(m) do
    %{"role" => Map.get(m, "role", "user"), "content" => Map.get(m, "content", "")}
  end

  defp build_user_content(text, nil), do: %{"role" => "user", "content" => text}

  defp build_user_content(text, media) when is_list(media) and media != [] do
    %{"role" => "user", "content" => text}
  end

  @doc """
  Add assistant message to messages list.
  """
  @spec add_assistant_message([message()], String.t() | nil, [map()] | nil, String.t() | nil) :: [message()]
  def add_assistant_message(messages, content, tool_calls \\ nil, reasoning_content \\ nil) do
    msg = %{"role" => "assistant", "content" => content || ""}

    msg =
      if tool_calls && tool_calls != [] do
        Map.put(msg, "tool_calls", tool_calls)
      else
        msg
      end

    msg =
      if reasoning_content do
        Map.put(msg, "reasoning_content", reasoning_content)
      else
        msg
      end

    messages ++ [msg]
  end

  @doc """
  Add tool result to messages list.
  """
  @spec add_tool_result([message()], String.t(), String.t(), String.t()) :: [message()]
  def add_tool_result(messages, tool_call_id, tool_name, result) do
    messages ++
      [
        %{
          "role" => "tool",
          "tool_call_id" => tool_call_id,
          "name" => tool_name,
          "content" => result
        }
      ]
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
