defmodule Nex.Agent.Memory do
  @moduledoc """
  Nanobot-style persistent memory store.

  The default memory model is two-layer only:
  - `memory/MEMORY.md` for long-term facts
  - `memory/HISTORY.md` for grep-friendly summaries
  """

  require Logger

  @default_workspace_path Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  @doc """
  Get the memory workspace path.
  """
  @spec workspace_path() :: String.t()
  def workspace_path do
    Application.get_env(:nex_agent, :workspace_path, @default_workspace_path)
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
  Append a grep-friendly history entry to HISTORY.md.
  """
  @spec append_history(String.t(), keyword()) :: :ok
  def append_history(entry, opts \\ []) do
    init(opts)
    history_file = Path.join(memory_dir(opts), "HISTORY.md")
    File.write!(history_file, String.trim_trailing(entry) <> "\n\n", [:append])
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
  @spec apply_memory_write(String.t(), String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_memory_write(action, target, content, old_text, opts \\ []) do
    target = normalize_target(target)
    current = read_target(target, opts)

    case action do
      "add" ->
        do_add_memory(target, current, content, opts)

      "replace" ->
        do_replace_memory(target, current, old_text, content, opts)

      "remove" ->
        do_remove_memory(target, current, old_text, opts)

      other ->
        {:error, "Unsupported memory action: #{inspect(other)}"}
    end
  end

  @doc """
  Consolidate old messages into MEMORY.md and HISTORY.md via LLM tool call.

  Returns `{:ok, session}` on success or no-op, `{:error, reason}` on failure.
  """
  @spec consolidate(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(session, provider, model, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    memory_window = Keyword.get(opts, :memory_window, 50)
    archive_all = Keyword.get(opts, :archive_all, false)
    workspace = Keyword.get(opts, :workspace)

    {old_messages, keep_count} =
      if archive_all do
        Logger.info("Memory consolidation (archive_all): #{length(session.messages)} messages")
        {session.messages, 0}
      else
        keep_count = div(memory_window, 2)

        cond do
          length(session.messages) <= keep_count ->
            {[], keep_count}

          length(session.messages) - session.last_consolidated <= 0 ->
            {[], keep_count}

          true ->
            {
              Enum.slice(
                session.messages,
                session.last_consolidated,
                length(session.messages) - keep_count - session.last_consolidated
              ),
              keep_count
            }
        end
      end

    if old_messages == [] do
      {:ok, session}
    else
      Logger.info(
        "Memory consolidation: #{length(old_messages)} to consolidate, #{keep_count} keep"
      )

      lines =
        old_messages
        |> Enum.reduce([], fn m, acc ->
          content = Map.get(m, "content")

          if is_nil(content) or content == "" do
            acc
          else
            tools =
              case Map.get(m, "tools_used") do
                tools when is_list(tools) and tools != [] -> " [tools: #{Enum.join(tools, ", ")}]"
                _ -> ""
              end

            timestamp = Map.get(m, "timestamp", "?") |> to_string() |> String.slice(0, 16)
            role = Map.get(m, "role", "") |> to_string() |> String.upcase()
            acc ++ ["[#{timestamp}] #{role}#{tools}: #{content}"]
          end
        end)

      memory_opts = workspace_opts(workspace)
      current_memory = read_long_term(memory_opts)

      prompt = """
      Process this conversation and call the save_memory tool with your consolidation.

      ## Current Long-term Memory
      #{if current_memory == "", do: "(empty)", else: current_memory}

      ## Conversation to Process
      #{Enum.join(lines, "\n")}
      """

      messages = [
        %{
          "role" => "system",
          "content" =>
            "You are a memory consolidation agent. Call the save_memory tool with your consolidation of the conversation."
        },
        %{"role" => "user", "content" => prompt}
      ]

      llm_opts = [
        provider: provider,
        model: model,
        api_key: api_key,
        base_url: base_url,
        tools: save_memory_tool(),
        tool_choice: tool_choice_for(provider, "save_memory")
      ]

      llm_call_fun =
        Keyword.get(opts, :llm_call_fun, &Nex.Agent.Runner.call_llm_for_consolidation/2)

      case llm_call_fun.(messages, llm_opts) do
        {:ok, result} ->
          case normalize_consolidation_args(result) do
            {:ok, args} ->
              apply_consolidation_result(
                args,
                session,
                current_memory,
                keep_count,
                archive_all,
                memory_opts
              )

            {:error, reason} ->
              Logger.warning("Memory consolidation: #{reason}")
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp save_memory_tool do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "save_memory",
          "description" => "Save the memory consolidation result to persistent storage.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "history_entry" => %{
                "type" => "string",
                "description" =>
                  "A paragraph (2-5 sentences) summarizing key events/decisions/topics. Start with [YYYY-MM-DD HH:MM]. Include detail useful for grep search."
              },
              "memory_update" => %{
                "type" => "string",
                "description" =>
                  "Full updated long-term memory as markdown. Include all existing facts plus new ones. Return unchanged if nothing new."
              }
            },
            "required" => ["history_entry", "memory_update"]
          }
        }
      }
    ]
  end

  defp normalize_consolidation_args(args) when is_map(args) do
    if map_size(args) == 0 do
      {:error, "missing save_memory payload"}
    else
      {:ok, args}
    end
  end

  defp normalize_consolidation_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} when is_list(decoded) ->
        normalize_consolidation_args(decoded)

      _ ->
        {:error, "unexpected arguments type string"}
    end
  end

  defp normalize_consolidation_args([first | _rest]) when is_map(first), do: {:ok, first}

  defp normalize_consolidation_args([]),
    do: {:error, "unexpected arguments as empty or non-dict list"}

  defp normalize_consolidation_args(_), do: {:error, "unexpected arguments type"}

  defp apply_consolidation_result(
         args,
         session,
         current_memory,
         keep_count,
         archive_all,
         memory_opts
       ) do
    entry = stringify_result(Map.get(args, "history_entry"))
    update = stringify_result(Map.get(args, "memory_update"))

    if entry != nil do
      append_history(entry, memory_opts)
    end

    if update != nil and update != current_memory do
      write_long_term(update, memory_opts)
    end

    updated_session = %{
      session
      | last_consolidated: if(archive_all, do: 0, else: length(session.messages) - keep_count)
    }

    Logger.info(
      "Memory consolidation done: #{length(session.messages)} messages, last_consolidated=#{updated_session.last_consolidated}"
    )

    {:ok, updated_session}
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
    Keyword.get(opts, :workspace, workspace_path())
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

  defp do_add_memory(_target, _current, nil, _opts), do: {:error, "content is required for add"}
  defp do_add_memory(_target, _current, "", _opts), do: {:error, "content is required for add"}

  defp do_add_memory(target, current, content, opts) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, "content is required for add"}
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
      {:ok, %{target: target, action: "add", content: trimmed}}
    end
  end

  defp do_replace_memory(_target, _current, old_text, _content, _opts)
       when old_text in [nil, ""] do
    {:error, "old_text is required for replace"}
  end

  defp do_replace_memory(_target, _current, _old_text, new_content, _opts)
       when new_content in [nil, ""] do
    {:error, "content is required for replace"}
  end

  defp do_replace_memory(target, current, old_text, new_content, opts) do
    case String.split(current, old_text, parts: 2) do
      [prefix, suffix] when suffix != current ->
        updated = prefix <> new_content <> suffix
        :ok = write_target(target, updated, opts)
        {:ok, %{target: target, action: "replace", old_text: old_text}}

      _ ->
        {:error, "old_text not found in #{target}"}
    end
  end

  defp do_remove_memory(_target, _current, old_text, _opts) when old_text in [nil, ""] do
    {:error, "old_text is required for remove"}
  end

  defp do_remove_memory(target, current, old_text, opts) do
    case String.split(current, old_text, parts: 2) do
      [prefix, suffix] when suffix != current ->
        updated =
          (prefix <> suffix)
          |> String.replace(~r/\n{3,}/, "\n\n")
          |> String.trim_trailing()
          |> Kernel.<>("\n")

        :ok = write_target(target, updated, opts)
        {:ok, %{target: target, action: "remove", old_text: old_text}}

      _ ->
        {:error, "old_text not found in #{target}"}
    end
  end

  defp tool_choice_for(:anthropic, name), do: %{type: "tool", name: name}

  defp tool_choice_for(_provider, name),
    do: %{type: "function", function: %{name: name}}
end
