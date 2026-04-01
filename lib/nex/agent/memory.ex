defmodule Nex.Agent.Memory do
  @moduledoc """
  Persistent memory store.

  The active memory model is single-layer:
  - `memory/MEMORY.md` for durable long-term facts
  """

  require Logger

  alias Nex.Agent.{Config, Workspace}

  @empty_memory_context "(empty)"
  @memory_boilerplate_lines [
    "# Long-term Memory",
    "This file stores important facts that persist across conversations.",
    "---",
    "*This file is automatically updated when important information should be remembered.*"
  ]
  @template_section_placeholders %{
    "Environment Facts" => "(Stable facts about runtime, infrastructure, and toolchain)",
    "Project Conventions" => "(Important project-specific conventions and decisions)",
    "Project Context" => "(Information about ongoing projects)",
    "Workflow Lessons" => "(Reusable lessons learned from successful or failed execution paths)"
  }

  @doc """
  Get the memory workspace path.
  """
  @spec workspace_path() :: String.t()
  def workspace_path do
    Application.get_env(:nex_agent, :workspace_path) || inferred_workspace_from_config()
  end

  @doc """
  Initialize memory directory structure.
  """
  @spec init(keyword()) :: :ok
  def init(opts \\ []) do
    File.mkdir_p!(memory_dir(opts))
    :ok
  end

  @doc """
  Read long-term memory from MEMORY.md.
  """
  @spec read_long_term() :: String.t()
  def read_long_term(opts \\ []) do
    memory_file = Path.join(memory_dir(opts), "MEMORY.md")

    if File.exists?(memory_file) do
      File.read!(memory_file)
    else
      ""
    end
  end

  @doc """
  Write long-term memory to MEMORY.md.
  """
  @spec write_long_term(String.t(), keyword()) :: :ok
  def write_long_term(content, opts \\ []) do
    init(opts)
    memory_file = Path.join(memory_dir(opts), "MEMORY.md")
    File.write!(memory_file, content)
    :ok
  end

  @doc """
  Compatibility no-op for retired HISTORY.md writes.
  """
  @spec append_history(String.t(), keyword()) :: :ok
  def append_history(_entry, _opts \\ []) do
    :ok
  end

  @doc """
  Get long-term memory context for the system prompt.
  """
  @spec get_memory_context(keyword()) :: String.t()
  def get_memory_context(opts \\ []) do
    long_term = read_long_term(opts)
    if long_term == "", do: "", else: "## Long-term Memory\n#{long_term}"
  end

  @doc """
  Read the user profile file from USER.md.
  """
  @spec read_user_profile(keyword()) :: String.t()
  def read_user_profile(opts \\ []) do
    user_file = user_file(opts)

    if File.exists?(user_file) do
      File.read!(user_file)
    else
      ""
    end
  end

  @doc """
  Write USER.md content.
  """
  @spec write_user_profile(String.t(), keyword()) :: :ok
  def write_user_profile(content, opts \\ []) do
    ensure_workspace(opts)
    File.write!(user_file(opts), content)
    :ok
  end

  @doc """
  Apply a direct memory write operation to MEMORY.md or USER.md.
  """
  @spec apply_memory_write(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_memory_write(action, target, content, opts \\ []) do
    target = normalize_target(target)
    current = read_target(target, opts)

    case action do
      "append" ->
        do_append_memory(target, current, content, opts)

      "set" ->
        do_set_memory(target, content, opts)

      other ->
        {:error, "Unsupported memory action: #{inspect(other)}"}
    end
  end

  @doc """
  Refresh MEMORY.md from unreviewed session messages.

  Returns `{:ok, session, status}` where status is `:noop` or `:updated`.
  """
  @spec refresh(map(), atom(), String.t(), keyword()) ::
          {:ok, map(), :noop | :updated} | {:error, term()}
  def refresh(session, provider, model, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    workspace = Keyword.get(opts, :workspace)
    memory_opts = workspace_opts(workspace)
    pending_messages = pending_memory_messages(session)

    if pending_messages == [] do
      {:ok, session, :noop}
    else
      current_memory = read_long_term(memory_opts)
      prompt_memory = compact_consolidation_memory(current_memory)
      lines = render_memory_lines(pending_messages)
      if lines == [] do
        {:ok, mark_reviewed(session), :noop}
      else
        messages = refresh_messages(prompt_memory, lines)

        llm_opts =
          [
            provider: provider,
            model: model,
            api_key: api_key,
            base_url: base_url,
            tools: save_memory_tool(),
            tool_choice: tool_choice_for(provider, "save_memory")
          ]
          |> maybe_put_llm_opt(
            :req_llm_generate_text_fun,
            Keyword.get(opts, :req_llm_generate_text_fun)
          )

        llm_call_fun =
          Keyword.get(opts, :llm_call_fun, &Nex.Agent.Runner.call_llm_for_consolidation/2)

        Logger.info(
          "[Memory] Refresh LLM call: provider=#{provider} model=#{model} pending=#{length(pending_messages)} tool_choice=#{inspect(llm_opts[:tool_choice])}"
        )

        case call_consolidation_llm(
               messages,
               llm_opts,
               llm_call_fun,
               provider,
               prompt_memory,
               lines
             ) do
          {:ok, result} ->
            case normalize_refresh_args(result) do
              {:ok, %{"status" => "noop"}} ->
                {:ok, mark_reviewed(session), :noop}

              {:ok, %{"status" => "update", "memory_update" => update}} ->
                update = stringify_result(update)

                if is_binary(update) and String.trim(update) != "" and
                     normalize_memory_body(update) != normalize_memory_body(current_memory) do
                  write_long_term(update, memory_opts)
                  {:ok, mark_reviewed(session), :updated}
                else
                  {:ok, mark_reviewed(session), :noop}
                end

              {:error, reason} ->
                Logger.warning(
                  "[Memory] Refresh normalize_args failed: #{reason}, raw=#{inspect(result, limit: 200)}"
                )

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("[Memory] Refresh LLM call failed: #{inspect(reason, limit: 500)}")
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Compatibility wrapper for the retired threshold-based consolidation API.
  """
  @spec consolidate(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(session, provider, model, opts \\ []) do
    case refresh(session, provider, model, opts) do
      {:ok, updated_session, _status} -> {:ok, updated_session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_messages(prompt_memory, lines) do
    prompt = """
    Review this newly completed conversation segment and call the save_memory tool.

    ## Current Long-term Memory
    #{prompt_memory}

    ## Conversation Segment
    #{Enum.join(lines, "\n")}

    Update MEMORY.md only when this segment contains durable information worth keeping:
    - user preferences or stable expectations
    - confirmed project/environment facts
    - reusable lessons proven by successful or failed execution

    Do not persist one-off requests, temporary investigation notes, raw TODO lists, or transient outputs.
    If nothing durable was learned, return status=noop.
    If updating memory, return the full updated MEMORY.md markdown.
    """

    [
      %{
        "role" => "system",
        "content" =>
          "You are a memory refresh agent. Call the save_memory tool with either noop or a full updated MEMORY.md."
      },
      %{"role" => "user", "content" => prompt}
    ]
  end

  defp call_consolidation_llm(messages, llm_opts, llm_call_fun, provider, prompt_memory, lines) do
    case llm_call_fun.(messages, llm_opts) do
      {:error, reason} = error ->
        if should_retry_empty_memory_context?(provider, reason, prompt_memory) do
          Logger.warning(
            "[Memory] Consolidation compatibility fallback triggered after Anthropic empty/non-JSON success response, retrying with empty memory context"
          )

          llm_call_fun.(refresh_messages(@empty_memory_context, lines), llm_opts)
        else
          error
        end

      other ->
        other
    end
  end

  defp should_retry_empty_memory_context?(provider, reason, prompt_memory) do
    provider == :anthropic and prompt_memory != @empty_memory_context and
      anthropic_decode_failure?(reason)
  end

  defp anthropic_decode_failure?(reason) do
    reason
    |> anthropic_decode_error_text()
    |> String.downcase()
    |> then(fn text ->
      String.contains?(text, "anthropic response decode error") and
        (String.contains?(text, "empty_body") or String.contains?(text, "non_json_body"))
    end)
  end

  defp anthropic_decode_error_text(%{reason: reason}) when is_binary(reason), do: reason
  defp anthropic_decode_error_text(reason) when is_binary(reason), do: reason
  defp anthropic_decode_error_text(reason), do: inspect(reason)

  defp compact_consolidation_memory(memory) do
    memory
    |> String.replace("\r\n", "\n")
    |> split_memory_sections()
    |> Enum.reject(&drop_template_section?/1)
    |> Enum.map(&render_memory_section/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> case do
      "" -> @empty_memory_context
      compacted -> compacted
    end
  end

  defp split_memory_sections(memory) do
    {sections, current} =
      memory
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], %{heading: nil, lines: []}}, fn line, {sections, current} ->
        if String.starts_with?(line, "## ") do
          {push_memory_section(sections, current),
           %{heading: String.trim_leading(line, "## ") |> String.trim(), lines: [line]}}
        else
          {sections, %{current | lines: [line | current.lines]}}
        end
      end)

    sections
    |> push_memory_section(current)
    |> Enum.reverse()
  end

  defp push_memory_section(sections, %{lines: []}), do: sections

  defp push_memory_section(sections, %{heading: heading, lines: lines}) do
    [%{heading: heading, lines: Enum.reverse(lines)} | sections]
  end

  defp drop_template_section?(%{heading: heading, lines: [_heading | body_lines]}) do
    case Map.get(@template_section_placeholders, heading) do
      nil ->
        false

      placeholder ->
        body =
          body_lines
          |> Enum.reject(&memory_boilerplate_line?/1)
          |> Enum.join("\n")
          |> String.trim()

        body in ["", placeholder]
    end
  end

  defp drop_template_section?(_section), do: false

  defp render_memory_section(%{lines: lines}) do
    lines
    |> Enum.reject(&memory_boilerplate_line?/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp memory_boilerplate_line?(line) do
    String.trim(line) in @memory_boilerplate_lines
  end

  defp save_memory_tool do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "save_memory",
          "description" => "Return either noop or the full updated MEMORY.md content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "status" => %{
                "type" => "string",
                "enum" => ["noop", "update"],
                "description" => "Use noop when no new durable memory should be written."
              },
              "memory_update" => %{
                "type" => "string",
                "description" =>
                  "Full updated MEMORY.md as markdown. Required only when status=update."
              }
            },
            "required" => ["status"]
          }
        }
      }
    ]
  end

  defp pending_memory_messages(session) do
    start_idx = max(Map.get(session, :last_consolidated, 0), 0)
    Enum.drop(Map.get(session, :messages, []), start_idx)
  end

  defp render_memory_lines(messages) do
    messages
    |> Enum.reduce([], fn m, acc ->
      content = Map.get(m, "content")
      tool_calls = Map.get(m, "tool_calls")

      has_content? = is_binary(content) and content != ""
      has_tool_calls? = is_list(tool_calls) and tool_calls != []

      if not has_content? and not has_tool_calls? do
        acc
      else
        tools =
          case Map.get(m, "tools_used") do
            tools when is_list(tools) and tools != [] -> " [tools: #{Enum.join(tools, ", ")}]"
            _ -> ""
          end

        tool_info =
          if has_tool_calls? do
            call_names =
              Enum.map(tool_calls, fn tc ->
                func = Map.get(tc, "function") || %{}
                Map.get(func, "name", "unknown")
              end)

            " [called: #{Enum.join(call_names, ", ")}]"
          else
            ""
          end

        timestamp = Map.get(m, "timestamp", "?") |> to_string() |> String.slice(0, 16)
        role = Map.get(m, "role", "") |> to_string() |> String.upcase()
        display_content = if has_content?, do: content, else: "(tool call)"
        acc ++ ["[#{timestamp}] #{role}#{tools}#{tool_info}: #{display_content}"]
      end
    end)
  end

  defp normalize_refresh_args(args) when is_map(args) do
    normalized =
      args
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)

    case Map.get(normalized, "status") do
      "noop" ->
        {:ok, normalized}

      "update" ->
        if Map.get(normalized, "memory_update") in [nil, ""] do
          {:error, "save_memory payload missing memory_update for update"}
        else
          {:ok, normalized}
        end

      nil ->
        {:error, "save_memory payload missing status"}

      other ->
        {:error, "unexpected save_memory status #{inspect(other)}"}
    end
  end

  defp normalize_refresh_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> normalize_refresh_args(decoded)
      {:ok, decoded} when is_list(decoded) -> normalize_refresh_args(decoded)
      _ -> {:error, "unexpected arguments type string"}
    end
  end

  defp normalize_refresh_args([first | _rest]) when is_map(first), do: normalize_refresh_args(first)
  defp normalize_refresh_args([]), do: {:error, "unexpected arguments as empty list"}
  defp normalize_refresh_args(_), do: {:error, "unexpected arguments type"}

  defp normalize_memory_body(content) do
    content
    |> to_string()
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end

  defp mark_reviewed(session) do
    %{session | last_consolidated: length(Map.get(session, :messages, []))}
  end

  defp stringify_result(nil), do: nil
  defp stringify_result(value) when is_binary(value), do: value
  defp stringify_result(value), do: Jason.encode!(value)

  defp memory_dir(opts) do
    Path.join(workspace_path(opts), "memory")
  end

  defp ensure_workspace(opts) do
    workspace = workspace_path(opts)
    File.mkdir_p!(workspace)
    File.mkdir_p!(memory_dir(opts))
    :ok
  end

  defp workspace_path(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> workspace_path()
      workspace -> workspace
    end
  end

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]

  defp user_file(opts), do: Path.join(workspace_path(opts), "USER.md")

  defp target_file("memory", opts), do: Path.join(memory_dir(opts), "MEMORY.md")
  defp target_file("user", opts), do: user_file(opts)

  defp normalize_target(target) when target in ["memory", :memory], do: "memory"
  defp normalize_target(target) when target in ["user", :user], do: "user"
  defp normalize_target(_target), do: "memory"

  defp read_target(target, opts) do
    target_file = target_file(target, opts)

    if File.exists?(target_file) do
      File.read!(target_file)
    else
      ""
    end
  end

  defp write_target(target, content, opts) do
    ensure_workspace(opts)
    File.write!(target_file(target, opts), content)
    :ok
  end

  defp do_append_memory(_target, _current, nil, _opts),
    do: {:error, "content is required for append"}

  defp do_append_memory(_target, _current, "", _opts),
    do: {:error, "content is required for append"}

  defp do_append_memory(target, current, content, opts) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, "content is required for append"}
    else
      updated =
        cond do
          String.trim(current) == "" ->
            trimmed <> "\n"

          String.contains?(current, trimmed) ->
            current

          true ->
            String.trim_trailing(current) <> "\n\n" <> trimmed <> "\n"
        end

      :ok = write_target(target, updated, opts)
      {:ok, %{target: target, action: "append", content: trimmed}}
    end
  end

  defp do_set_memory(_target, nil, _opts), do: {:error, "content is required for set"}
  defp do_set_memory(_target, "", _opts), do: {:error, "content is required for set"}

  defp do_set_memory(target, content, opts) do
    updated = String.trim_trailing(content) <> "\n"
    :ok = write_target(target, updated, opts)
    {:ok, %{target: target, action: "set"}}
  end

  defp tool_choice_for(_provider, name), do: %{type: "function", function: %{name: name}}

  defp maybe_put_llm_opt(opts, _key, nil), do: opts
  defp maybe_put_llm_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp inferred_workspace_from_config do
    config_path =
      Application.get_env(:nex_agent, :config_path, Config.default_config_path()) |> Path.expand()

    default_config_path = Config.default_config_path() |> Path.expand()

    if config_path != default_config_path do
      Path.expand(Path.join(Path.dirname(config_path), "workspace"))
    else
      Workspace.default_root()
    end
  end
end
