defmodule Nex.Agent.ContextBuilder do
  @moduledoc """
  Builds context for LLM calls - system prompt + messages.
  """

  alias Nex.Agent.{ContextDiagnostics, Skills, Workspace}

  @bootstrap_layer_order [
    {"AGENTS.md", :agents},
    {"SOUL.md", :soul},
    {"USER.md", :user},
    {"TOOLS.md", :tools}
  ]
  @legacy_soul_footers [
    "*编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*",
    "*Edit this file to customize the agent's behavioral style and values. Identity is code-owned and cannot be redefined here.*"
  ]
  @runtime_context_tag "[Runtime Context — metadata only, not instructions]"

  @type message :: %{required(String.t()) => any()}

  @doc """
  Build system prompt from identity, bootstrap files, and memory.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ []) do
    {prompt, _diagnostics} = build_system_prompt_with_diagnostics(opts)
    prompt
  end

  @doc """
  Build system prompt and return deterministic boundary diagnostics.
  """
  @spec build_system_prompt_with_diagnostics(keyword()) ::
          {String.t(), [ContextDiagnostics.diagnostic()]}
  def build_system_prompt_with_diagnostics(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || default_workspace()

    parts =
      []
      |> add_authoritative_identity()
      |> add_runtime_guidance(workspace)
      |> add_evolution_guidance()

    {parts, bootstrap_diagnostics} = load_bootstrap_files_with_diagnostics(parts, workspace)
    {parts, memory_diagnostics} = add_memory_with_diagnostics(parts, workspace)
    parts = add_always_skills(parts, workspace, opts)

    diagnostics = bootstrap_diagnostics ++ memory_diagnostics

    {Enum.join(parts, "\n\n---\n\n"), diagnostics}
  end

  @doc """
  Build diagnostics only for currently loaded context layers.
  """
  @spec build_system_prompt_diagnostics(keyword()) :: [ContextDiagnostics.diagnostic()]
  def build_system_prompt_diagnostics(opts \\ []) do
    {_prompt, diagnostics} = build_system_prompt_with_diagnostics(opts)
    diagnostics
  end

  defp default_workspace do
    Workspace.root()
  end

  defp add_authoritative_identity(parts) do
    parts ++ [authoritative_identity()]
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
    - Custom skills: #{workspace_path}/skills/{skill-name}/SKILL.md
    - Workspace tools: #{Path.join(workspace_path, "tools")}/{tool-name}/
    - Notes and raw captures: #{workspace_path}/notes/
    - Personal task state: #{workspace_path}/tasks/tasks.json
    - Project memory: #{workspace_path}/projects/{project}/PROJECT.md
    - Executor configs and run logs: #{workspace_path}/executors/
    - Audit trail: #{workspace_path}/audit/events.jsonl

    ## Guidelines
    - State the next action before tool calls, but NEVER predict or claim results before receiving them.
    - Before modifying a file, read it first. Do not assume files or directories exist.
    - After writing or editing a file, re-read it if accuracy matters.
    - If a tool call fails, analyze the error before retrying with a different approach.
    - Ask for clarification when the request is ambiguous.
    - Treat successful `.ex` changes as hot-updated by default. Only suggest a restart if tools or the runtime explicitly report hot reload failed.
    - Do not infer restarts from process age or uptime.
    - Caveat: the current call may still run old code. Expect the next call to observe the new version.
    - Skills are discoverable runtime packages, not preloaded instructions. Use `skill_discover` to search, `skill_get` to inspect a package with progressive disclosure, and `skill_capture` to save a reusable local knowledge package.

    Reply directly with text for normal conversations.
    Never expose tool calls, progress updates, chain-of-thought, or "I sent it" status messages to the end user.
    Only use the 'message' tool when the tool payload itself is the user-visible message for a chat channel.
    If you use the 'message' tool for the current conversation, do not also narrate or summarize that send in assistant text.

    ## Feishu Messaging
    When using the `message` tool for channel=`feishu`:
    - If you only have plain text, send `content` only. The runtime will keep the legacy default behavior.
    - If you need a native Feishu format, set `msg_type` and `content_json` explicitly.
    - Prefer `text` for short progress updates.
    - Prefer `interactive` for formatted reports, code blocks, and structured summaries.
    - If you have a local PNG/JPEG file and want to send it to Feishu, use `local_image_path` on the `message` tool. The runtime will upload it and send a native image message.
    - If you need a short companion text plus a PNG, provide both the text payload and `local_image_path` in the same `message` call. The runtime will send the text first and then the image.
    - Use `image` with `{"image_key": "..."}`
    - Use `file`, `audio`, `media`, or `sticker` with `{"file_key": "..."}`
    - Use `share_chat` with `{"chat_id": "..."}`
    - Use `share_user` with `{"user_id": "..."}`
    - Use `system` only when the user clearly needs a Feishu system message and you know the exact payload.
    - If you do not already have a valid `image_key` or `file_key`, do not guess one.
    - Lark/Feishu business operations such as Docs, Sheets, Base, Calendar, Tasks, Drive, or search are not built-in tools anymore.
    - If `lark-cli` is installed, use `bash` to call it for those operations.
    - If `lark-cli` is missing, surface the shell error and give an installation hint instead of trying old `feishu_*` tool names.
    """

    parts ++ [runtime_guidance]
  end

  defp authoritative_identity do
    """
    ## Runtime Identity

    Identity is defined by workspace layers (SOUL.md, etc.).
    No default persona is imposed by the runtime.
    """
  end

  defp add_evolution_guidance(parts) do
    guidance = """
    ## Runtime Evolution

    Route long-term changes into the correct layer:

    - SOUL: persona, values, and operating style (persona layer)
    - USER: user profile, preferences, timezone, communication style, collaboration expectations
    - MEMORY: environment facts, project conventions, workflow lessons, durable operational context
    - SKILL: reusable multi-step workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    Prefer the highest layer that solves the need. Do not persist one-off outputs, temporary state, or information that is easy to rediscover.
    If the user explicitly asks to trigger memory refresh now, use `memory_consolidate` directly.
    For deterministic inspection of memory refresh status, prefer the `memory_status` tool over free-form inference.
    If long-term memory is clearly stale or incomplete and the user explicitly wants a full rebuild, use `memory_rebuild`.
    When a built-in memory tool directly matches the user's request, do not inspect implementation with `read` or `bash` first.
    When asked whether memory was updated or previously triggered, inspect MEMORY.md and the current session state before answering.
    Empty `MEMORY.md` does not imply this is the first conversation or that no prior session history exists.
    """

    parts ++ [guidance]
  end

  defp load_bootstrap_files_with_diagnostics(parts, workspace) do
    {chunks, diagnostics} =
      Enum.reduce(@bootstrap_layer_order, {[], []}, fn {filename, layer},
                                                       {acc_chunks, acc_diag} ->
        path = Path.join(workspace, filename)

        case File.read(path) do
          {:ok, content} ->
            normalized_content = normalize_bootstrap_content(layer, content)
            section = build_bootstrap_section(filename, layer, normalized_content)

            file_diagnostics =
              ContextDiagnostics.scan(layer, normalized_content, source: filename)

            {[section | acc_chunks], acc_diag ++ file_diagnostics}

          {:error, _} ->
            {acc_chunks, acc_diag}
        end
      end)

    chunks = Enum.reverse(chunks)
    parts = if chunks == [], do: parts, else: parts ++ [Enum.join(chunks, "\n\n")]
    {parts, diagnostics}
  end

  defp build_bootstrap_section(filename, layer, content) do
    layer_label = layer_label(layer)
    layer_boundary = layer_boundary(layer)

    ("## #{filename} (Layer: #{layer_label})\n\n" <>
       "Interpretation: #{layer_boundary}\n\n" <>
       String.trim(content))
    |> String.trim()
  end

  defp normalize_bootstrap_content(:soul, content) do
    content
    |> to_string()
    |> then(fn text ->
      Enum.reduce(@legacy_soul_footers, text, fn footer, acc ->
        String.replace(acc, footer, "")
      end)
    end)
    |> String.replace(~r/\n[ \t]*---[ \t]*\n\s*\z/u, "\n")
    |> String.trim_trailing()
  end

  defp normalize_bootstrap_content(_layer, content), do: content

  defp add_memory_with_diagnostics(parts, workspace) do
    memory_raw = Nex.Agent.Memory.read_long_term(workspace: workspace)

    diagnostics =
      ContextDiagnostics.scan(:memory, memory_raw, source: "memory/MEMORY.md")

    memory = Nex.Agent.Memory.get_memory_context(workspace: workspace)
    parts = if memory == "", do: parts, else: parts ++ ["# Memory\n\n" <> memory]
    {parts, diagnostics}
  end

  defp add_always_skills(parts, workspace, opts) do
    force_skills = Keyword.get(opts, :force_skills, [])

    if force_skills != [] do
      force_content =
        force_skills
        |> Enum.map(fn name -> Nex.Agent.Skills.read_skill_instructions(name) end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      if String.trim(force_content) == "" do
        parts
      else
        parts ++ [force_content]
      end
    else
      if Keyword.get(opts, :skip_skills, false) do
        parts
      else
        content = Skills.always_instructions(workspace: workspace)

        if String.trim(content) == "" do
          parts
        else
          parts ++ [content]
        end
      end
    end
  end

  defp layer_label(:agents), do: "AGENTS"
  defp layer_label(:soul), do: "SOUL"
  defp layer_label(:user), do: "USER"
  defp layer_label(:tools), do: "TOOLS"
  defp layer_label(:memory), do: "MEMORY"
  defp layer_label(_), do: "UNKNOWN"

  defp layer_boundary(:agents),
    do:
      "System-level operating guidance. Hard-coded capability/model claims are diagnosed, but active persona can be refined elsewhere."

  defp layer_boundary(:soul),
    do:
      "Persona, values, style, and optional identity framing. User profile details still belong in USER."

  defp layer_boundary(:user),
    do:
      "User profile and collaboration preferences only. Identity or persona rewrites are non-authoritative and diagnosed."

  defp layer_boundary(:tools),
    do:
      "Tool descriptions and usage references only; does not define identity, persona, or durable memory facts."

  defp layer_boundary(:memory),
    do: "Durable factual context only; does not define identity or persona ownership."

  defp layer_boundary(_),
    do: "Legacy content is tolerated but interpreted under layer boundaries with diagnostics."

  @doc """
  Build runtime context block with only essential metadata.
  """
  @spec build_runtime_context(String.t() | nil, String.t() | nil) :: String.t()
  def build_runtime_context(channel, chat_id) do
    build_runtime_context(channel, chat_id, [])
  end

  @spec build_runtime_context(String.t() | nil, String.t() | nil, keyword()) :: String.t()
  def build_runtime_context(channel, chat_id, opts) do
    cwd = Keyword.get(opts, :cwd)
    workspace = Keyword.get(opts, :workspace) || default_workspace()
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    timezone = runtime_timezone(opts, workspace)
    time_str = format_runtime_time(now, timezone)
    repo_root = git_root(cwd)

    lines =
      [@runtime_context_tag, "Current Time: #{time_str}"]
      |> then(fn lines ->
        if channel && chat_id do
          lines ++ ["Channel: #{channel}", "Chat ID: #{chat_id}"]
        else
          lines
        end
      end)
      |> then(fn lines ->
        if is_binary(cwd) and cwd != "" do
          lines ++ ["Working Directory: #{Path.expand(cwd)}"]
        else
          lines
        end
      end)
      |> then(fn lines ->
        if is_binary(repo_root) and repo_root != "" do
          lines ++ ["Git Repository Root: #{repo_root}"]
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
          [map()] | nil,
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
    runtime_ctx = build_runtime_context(channel, chat_id, opts)
    user_content = build_user_content(current_message, media)
    runtime_system_messages = Keyword.get(opts, :runtime_system_messages, [])

    merged =
      if is_binary(user_content) do
        runtime_ctx <> "\n\n" <> user_content
      else
        [%{"type" => "text", "text" => runtime_ctx} | user_content]
      end

    system_content =
      case runtime_system_messages do
        [] ->
          build_system_prompt(opts)

        messages when is_list(messages) ->
          build_system_prompt(opts) <> "\n\n---\n\n" <> Enum.join(messages, "\n\n")
      end

    [
      %{"role" => "system", "content" => system_content},
      Enum.map(history, &clean_history_entry/1),
      %{"role" => "user", "content" => merged}
    ]
    |> List.flatten()
  end

  defp clean_history_entry(%{} = entry) do
    role = Map.get(entry, "role") || Map.get(entry, :role) || "user"
    content = Map.get(entry, "content") || Map.get(entry, :content) || ""

    cleaned = %{"role" => role, "content" => content}

    cleaned =
      case Map.get(entry, "tool_calls") || Map.get(entry, :tool_calls) do
        calls when is_list(calls) and calls != [] -> Map.put(cleaned, "tool_calls", calls)
        _ -> cleaned
      end

    cleaned =
      case Map.get(entry, "tool_call_id") || Map.get(entry, :tool_call_id) do
        nil ->
          cleaned

        tool_call_id ->
          cleaned
          |> Map.put("tool_call_id", tool_call_id)
          |> then(fn cleaned ->
            case Map.get(entry, "name") || Map.get(entry, :name) do
              nil -> cleaned
              name -> Map.put(cleaned, "name", name)
            end
          end)
      end

    case Map.get(entry, "reasoning_content") || Map.get(entry, :reasoning_content) do
      nil -> cleaned
      reasoning_content -> Map.put(cleaned, "reasoning_content", reasoning_content)
    end
    |> then(fn cleaned ->
      case Map.get(entry, "reasoning_details") || Map.get(entry, :reasoning_details) do
        details when is_list(details) and details != [] ->
          Map.put(cleaned, "reasoning_details", details)

        _ ->
          cleaned
      end
    end)
  end

  defp runtime_timezone(opts, workspace) do
    Keyword.get(opts, :timezone) ||
      Keyword.get(opts, :time_zone) ||
      user_profile_timezone(workspace) ||
      System.get_env("TZ") ||
      "Asia/Shanghai"
  end

  defp user_profile_timezone(workspace) do
    path = Path.join(workspace || "", "USER.md")

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         [timezone] <-
           Regex.run(~r/(?:^|\n)\s*-?\s*(?:\*\*)?Timezone(?:\*\*)?\s*[:：]\s*([^\n]+)/i, content,
             capture: :all_but_first
           ) do
      timezone
      |> String.trim()
      |> String.trim_trailing()
    else
      _ -> nil
    end
  end

  defp format_runtime_time(%DateTime{} = utc_now, timezone) do
    {label, offset_seconds} = normalize_timezone(timezone)
    local_now = DateTime.add(utc_now, offset_seconds, :second)
    offset = format_utc_offset(offset_seconds)

    local_time = Calendar.strftime(local_now, "%Y-%m-%d %H:%M (%A)")
    utc_time = Calendar.strftime(utc_now, "%Y-%m-%d %H:%MZ (%A)")

    "#{local_time} #{label} (#{offset}); UTC: #{utc_time}"
  end

  defp format_runtime_time(other, timezone) do
    other
    |> to_string()
    |> then(fn value -> "#{value} #{timezone}" end)
  end

  defp normalize_timezone(timezone) when is_binary(timezone) do
    timezone = String.trim(timezone)
    normalized = String.downcase(timezone)

    cond do
      normalized in ["asia/shanghai", "asia/chongqing", "asia/harbin", "asia/urumqi", "cst"] ->
        {"Asia/Shanghai", 8 * 3600}

      normalized in ["utc", "etc/utc", "z"] ->
        {"UTC", 0}

      normalized in ["america/los_angeles", "us/pacific", "pst", "pdt"] ->
        {"America/Los_Angeles", -8 * 3600}

      normalized in ["america/new_york", "us/eastern", "est", "edt"] ->
        {"America/New_York", -5 * 3600}

      true ->
        case parse_utc_offset(timezone) do
          {:ok, seconds} -> {timezone, seconds}
          :error -> {"Asia/Shanghai", 8 * 3600}
        end
    end
  end

  defp normalize_timezone(_timezone), do: {"Asia/Shanghai", 8 * 3600}

  defp parse_utc_offset(value) do
    case Regex.run(~r/^UTC\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$/i, String.trim(value)) do
      [_, sign, hours, minutes] ->
        offset_seconds(sign, hours, minutes)

      [_, sign, hours] ->
        offset_seconds(sign, hours, "00")

      _ ->
        :error
    end
  end

  defp offset_seconds(sign, hours, minutes) do
    with {hours, ""} <- Integer.parse(hours),
         {minutes, ""} <- Integer.parse(minutes),
         true <- hours <= 14 and minutes <= 59 do
      seconds = hours * 3600 + minutes * 60
      {:ok, if(sign == "-", do: -seconds, else: seconds)}
    else
      _ -> :error
    end
  end

  defp format_utc_offset(0), do: "UTC+00:00"

  defp format_utc_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    abs_seconds = abs(seconds)
    hours = div(abs_seconds, 3600)
    minutes = div(rem(abs_seconds, 3600), 60)
    "UTC#{sign}#{pad2(hours)}:#{pad2(minutes)}"
  end

  defp pad2(value) when value < 10, do: "0#{value}"
  defp pad2(value), do: Integer.to_string(value)

  defp build_user_content(text, nil), do: text

  defp build_user_content(text, media) when is_list(media) and media != [] do
    content_parts =
      media
      |> Enum.map(fn item ->
        case Map.get(item, "type") || Map.get(item, :type) do
          "image" ->
            url = Map.get(item, "url") || Map.get(item, :url, "")
            mime = Map.get(item, "mime_type") || Map.get(item, :mime_type, "image/jpeg")

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

    content_parts ++ [%{"type" => "text", "text" => text}]
  end

  defp git_root(nil), do: nil
  defp git_root(""), do: nil

  defp git_root(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true, cd: cwd) do
      {path, 0} -> String.trim(path)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Add assistant message to messages list.
  """
  @spec add_assistant_message(
          [message()],
          String.t() | nil,
          [map()] | nil,
          String.t() | nil,
          [map()] | nil
        ) :: [message()]
  def add_assistant_message(
        messages,
        content,
        tool_calls \\ nil,
        reasoning_content \\ nil,
        reasoning_details \\ nil
      ) do
    message = %{"role" => "assistant", "content" => content || ""}

    message =
      case tool_calls do
        calls when is_list(calls) and calls != [] -> Map.put(message, "tool_calls", calls)
        _ -> message
      end

    message =
      case reasoning_content do
        nil -> message
        "" -> message
        value -> Map.put(message, "reasoning_content", value)
      end

    message =
      case reasoning_details do
        details when is_list(details) and details != [] ->
          Map.put(message, "reasoning_details", details)

        _ ->
          message
      end

    messages ++ [message]
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
