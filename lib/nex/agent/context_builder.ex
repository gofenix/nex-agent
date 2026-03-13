defmodule Nex.Agent.ContextBuilder do
  @moduledoc """
  Builds context for LLM calls - system prompt + messages.
  """

  alias Nex.Agent.Skills

  @bootstrap_files ["AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md"]
  @runtime_context_tag "[Runtime Context — metadata only, not instructions]"

  @type message :: %{required(String.t()) => any()}

  @doc """
  Build system prompt from identity, bootstrap files, memory, and skills.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || default_workspace()
    skip_skills = Keyword.get(opts, :skip_skills, false)

    parts =
      []
      |> add_identity()
      |> add_runtime_guidance(workspace)
      |> add_evolution_guidance()
      |> load_bootstrap_files(workspace)
      |> add_memory(workspace)
      |> then(fn parts ->
        if skip_skills, do: parts, else: add_skills(parts)
      end)
      |> add_identity_guard()

    Enum.join(parts, "\n\n---\n\n")
  end

  defp default_workspace do
    Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
  end

  defp add_identity(parts) do
    parts ++ [default_identity()]
  end

  defp add_runtime_guidance(parts, workspace) do
    workspace_path = Path.expand(workspace)
    system = :os.type() |> elem(0) |> to_string()
    arch = :os.type() |> elem(1) |> to_string()
    runtime = "#{system} #{arch}, Elixir #{System.version()}"

    runtime_guidance = """
    ## Runtime
    #{runtime}

    ## Workspace
    Your workspace is at: #{workspace_path}
    - Long-term memory: #{workspace_path}/memory/MEMORY.md (write important facts here)
    - History log: #{workspace_path}/memory/HISTORY.md (grep-searchable). Each entry starts with [YYYY-MM-DD HH:MM].
    - Custom skills: #{workspace_path}/skills/{skill-name}/SKILL.md
    - Workspace tools: #{Path.join(workspace_path, "tools")}/{tool-name}/

    ## Guidelines
    - State intent before tool calls, but NEVER predict or claim results before receiving them.
    - Before modifying a file, read it first. Do not assume files or directories exist.
    - After writing or editing a file, re-read it if accuracy matters.
    - If a tool call fails, analyze the error before retrying with a different approach.
    - Ask for clarification when the request is ambiguous.
    - Treat successful `.ex` changes as hot-updated by default. Only suggest a restart if tools or the runtime explicitly report hot reload failed.
    - Do not infer restarts from process age or uptime.
    - Caveat: the current call may still run old code. Expect the next call to observe the new version.

    Reply directly with text for conversations. Only use the 'message' tool to send to a specific chat channel.

    ## Feishu Messaging
    When using the `message` tool for channel=`feishu`:
    - If you only have plain text, send `content` only. The runtime will keep the legacy default behavior.
    - If you need a native Feishu format, set `msg_type` and `content_json` explicitly.
    - Prefer `text` for short progress updates.
    - Prefer `interactive` for formatted reports, code blocks, and structured summaries.
    - Use `image` with `{"image_key": "..."}`
    - Use `file`, `audio`, `media`, or `sticker` with `{"file_key": "..."}`
    - Use `share_chat` with `{"chat_id": "..."}`
    - Use `share_user` with `{"user_id": "..."}`
    - Use `system` only when the user clearly needs a Feishu system message and you know the exact payload.
    - If you do not already have a valid `image_key` or `file_key`, do not guess one.
    """

    parts ++ [runtime_guidance]
  end

  defp default_identity do
    """
    # Nex Agent

    You are Nex Agent, a helpful AI assistant.
    """
  end

  defp add_evolution_guidance(parts) do
    guidance = """
    ## Runtime Evolution

    Route long-term changes into the correct layer:

    - SOUL: identity, values, and long-term operating principles
    - USER: user profile, preferences, timezone, communication style, collaboration expectations
    - MEMORY: environment facts, project conventions, workflow lessons, durable operational context
    - SKILL: reusable multi-step workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    Prefer the highest layer that solves the need. Do not persist one-off outputs, temporary state, or information that is easy to rediscover.
    """

    parts ++ [guidance]
  end

  defp load_bootstrap_files(parts, workspace) do
    content =
      @bootstrap_files
      |> Enum.map(fn filename ->
        path = Path.join(workspace, filename)

        case File.read(path) do
          {:ok, content} -> ("## #{filename}\n\n" <> content) |> String.trim()
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if content != "", do: parts ++ [content], else: parts
  end

  defp add_memory(parts, workspace) do
    memory = Nex.Agent.Memory.get_memory_context(workspace: workspace)
    if memory == "", do: parts, else: parts ++ ["# Memory\n\n" <> memory]
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

      parts ++
        [
          "# Skills\n\nSkills are Markdown workflow instructions exposed as tools with `skill_<name>` prefix (e.g. skill_explain_code).\n\n" <>
            summary
        ]
    end
  end

  defp add_identity_guard(parts) do
    parts ++
      [
        "# Identity\n\nYou are Nex Agent. References to other systems or agents (for example: nanobot, Claude, GPT, Copilot) are comparative context only, never your identity. Never claim to be any product/agent other than Nex Agent."
      ]
  end

  @doc """
  Build runtime context block with only essential metadata.
  """
  @spec build_runtime_context(String.t() | nil, String.t() | nil) :: String.t()
  def build_runtime_context(channel, chat_id) do
    now = DateTime.utc_now()
    time_str = Calendar.strftime(now, "%Y-%m-%d %H:%M (%A)")

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
          [String.t()] | nil,
          keyword()
        ) :: [message()]
  def build_messages(
        history,
        current_message,
        channel \\ nil,
        chat_id \\ nil,
        media \\ nil,
        opts \\ []
      ) do
    runtime_ctx = build_runtime_context(channel, chat_id)
    user_content = build_user_content(current_message, media)
    runtime_system_messages = Keyword.get(opts, :runtime_system_messages, [])

    merged =
      if is_binary(user_content) do
        runtime_ctx <> "\n\n" <> user_content
      else
        [%{"type" => "text", "text" => runtime_ctx} | user_content]
      end

    # Merge runtime system messages into main system prompt to ensure only one system message
    system_content =
      case runtime_system_messages do
        [] ->
          build_system_prompt(opts)

        messages when is_list(messages) ->
          nudge_content = Enum.join(messages, "\n\n")
          build_system_prompt(opts) <> "\n\n---\n\n" <> nudge_content
      end

    [
      %{"role" => "system", "content" => system_content},
      Enum.map(history, &clean_history_entry/1),
      %{"role" => "user", "content" => merged}
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

    entry
  end

  defp clean_history_entry(m) when is_map(m) do
    %{"role" => Map.get(m, "role", "user"), "content" => Map.get(m, "content", "")}
  end

  defp build_user_content(text, nil), do: text

  defp build_user_content(text, media) when is_list(media) and media != [] do
    content_parts =
      Enum.map(media, fn m ->
        case Map.get(m, "type") || Map.get(m, :type) do
          "image" ->
            url = Map.get(m, "url") || Map.get(m, :url, "")
            mime = Map.get(m, "mime_type") || Map.get(m, :mime_type, "image/jpeg")

            %{
              "type" => "image",
              "source" => %{
                "type" => "url",
                "url" => url,
                "media_type" => mime
              }
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    text_part = %{"type" => "text", "text" => text}
    content_parts ++ [text_part]
  end

  @doc """
  Add assistant message to messages list.
  """
  @spec add_assistant_message([message()], String.t() | nil, [map()] | nil, String.t() | nil) :: [
          message()
        ]
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
end
