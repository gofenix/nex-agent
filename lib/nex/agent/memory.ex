defmodule Nex.Agent.Memory do
  @moduledoc """
  Agent memory system - daily logs with BM25 search.

  ## Structure

      ~/.nex/agent/workspace/
      ├── memory/
      │   ├── 2026-02-27.md
      │   ├── 2026-02-26.md
      │   └── ...

  ## Usage

      # Append to today's log
      :ok = Nex.Agent.Memory.append("Task: Fix login", "Success", %{tool: "bash", command: "..."})

      # Search memories
      results = Nex.Agent.Memory.search("login bug")

      # Get today's entries
      entries = Nex.Agent.Memory.today()
  """

  @workspace_path Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
  @memory_dir Path.join(@workspace_path, "memory")

  @doc """
  Get the memory workspace path.
  """
  @spec workspace_path() :: String.t()
  def workspace_path, do: @workspace_path

  @doc """
  Initialize memory directory structure.
  """
  @spec init() :: :ok
  def init do
    File.mkdir_p!(@memory_dir)
    :ok
  end

  @doc """
  Append an entry to today's memory log.

  ## Parameters

  * `task` - Task description
  * `result` - Result ("SUCCESS", "FAILURE", etc.)
  * `metadata` - Optional metadata map

  ## Examples

      Nex.Agent.Memory.append("Fix login bug", "SUCCESS", %{tool: "bash", command: "git commit -m 'fix'"})
  """
  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(task, result, metadata \\ %{}) do
    init()

    today = Date.utc_today() |> Date.to_string()
    date_dir = Path.join(@memory_dir, today)
    File.mkdir_p!(date_dir)

    timestamp = Time.utc_now() |> Time.to_string() |> String.slice(0..7)
    entry_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    entry = format_entry(timestamp, entry_id, task, result, metadata)

    file_path = Path.join(date_dir, "log.md")

    case File.open(file_path, [:append, :utf8]) do
      {:ok, file} ->
        IO.write(file, entry)
        File.close(file)

        # Notify index for incremental update
        if Process.whereis(Nex.Agent.Memory.Index) do
          doc_id = "daily:#{today}-#{entry_id}"

          doc = %{
            text: "#{task} #{result}",
            task: task,
            date: Date.utc_today(),
            source: :daily
          }

          Nex.Agent.Memory.Index.add_document(doc_id, doc)
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get all entries for today.
  """
  @spec today() :: list(map())
  def today do
    today = Date.utc_today() |> Date.to_string()
    read_date(today)
  end

  @doc """
  Get entries for a specific date.

  ## Examples

      entries = Nex.Agent.Memory.get("2026-02-27")
  """
  @spec get(String.t()) :: list(map())
  def get(date) when is_binary(date), do: read_date(date)

  @doc """
  Get entries for a date range.
  """
  @spec get_range(String.t(), String.t()) :: list(map())
  def get_range(from_date, to_date) do
    from = Date.from_iso8601!(from_date)
    to = Date.from_iso8601!(to_date)

    Date.range(from, to)
    |> Enum.flat_map(&get(Date.to_string(&1)))
  end

  @doc """
  Search memories using BM25 via Memory.Index (with TF fallback).
  """
  @spec search(String.t(), keyword()) :: list(map())
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source, :all)

    # Try Index first (100ms timeout built-in)
    case Process.whereis(Nex.Agent.Memory.Index) do
      nil ->
        fallback_search(query, limit)

      _pid ->
        results = Nex.Agent.Memory.Index.search(query, limit: limit, source: source)

        if results == [] do
          fallback_search(query, limit)
        else
          results
        end
    end
  end

  @doc """
  Reindex all memories (for BM25).
  """
  @spec reindex() :: :ok
  def reindex do
    case Process.whereis(Nex.Agent.Memory.Index) do
      nil -> :ok
      _pid -> Nex.Agent.Memory.Index.rebuild()
    end
  end

  # Private functions

  defp read_date(date) do
    date_dir = Path.join(@memory_dir, date)
    log_file = Path.join(date_dir, "log.md")

    if File.exists?(log_file) do
      content = File.read!(log_file)
      parse_entries(content)
    else
      []
    end
  end

  @doc "Read all daily log entries. Used by Memory.Index for indexing."
  def read_all_entries do
    if File.exists?(@memory_dir) do
      @memory_dir
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, &1))
      |> Enum.flat_map(fn date_str ->
        read_date(date_str)
        |> Enum.map(&Map.put(&1, :date_str, date_str))
      end)
    else
      []
    end
  end

  defp parse_entries(content) do
    content
    |> String.split("## ")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_entry(entry) do
    [header | lines] = String.split(entry, "\n", parts: 2)

    parts = String.split(header, " - ", parts: 3)

    case parts do
      [timestamp, id, task_result] ->
        case String.split(task_result, ": ", parts: 2) do
          [task, result] ->
            body = if length(lines) > 0, do: hd(lines), else: ""

            %{
              timestamp: String.trim(timestamp),
              id: String.trim(id),
              task: String.trim(task),
              result: String.trim(result),
              body: String.trim(body)
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp format_entry(timestamp, id, task, result, metadata) do
    meta_str =
      if map_size(metadata) > 0 do
        "\n\n```json\n#{Jason.encode!(metadata)}\n```"
      else
        ""
      end

    "## #{timestamp} - #{id} - #{task}: #{result}#{meta_str}\n"
  end

  # BM25 scoring (simplified fallback when Index is unavailable)

  defp fallback_search(query, limit) do
    read_all_entries()
    |> Enum.map(&score_entry(&1, query))
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp score_entry(entry, query) do
    # Combine all text fields
    text =
      "#{entry.task} #{entry.body} #{entry.result}"
      |> String.downcase()

    query_terms =
      query
      |> String.downcase()
      |> String.split()

    score =
      Enum.reduce(query_terms, 0, fn term, acc ->
        if String.contains?(text, term) do
          # Simple TF scoring
          count = Regex.scan(~r/#{Regex.escape(term)}/, text) |> length()
          acc + count
        else
          acc
        end
      end)

    %{entry: entry, score: score}
  end

  @doc """
  Read long-term memory from MEMORY.md
  """
  @spec read_long_term() :: String.t()
  def read_long_term do
    memory_file = Path.join(@memory_dir, "MEMORY.md")

    if File.exists?(memory_file) do
      File.read!(memory_file)
    else
      ""
    end
  end

  @doc """
  Write long-term memory to MEMORY.md
  """
  @spec write_long_term(String.t()) :: :ok
  def write_long_term(content) do
    init()
    memory_file = Path.join(@memory_dir, "MEMORY.md")
    File.write!(memory_file, content)
    :ok
  end

  @doc """
  Append to HISTORY.md (grep-searchable log)
  """
  @spec append_history(String.t()) :: :ok
  def append_history(entry) do
    init()
    history_file = Path.join(@memory_dir, "HISTORY.md")

    timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.slice(0..15)
    formatted = "[#{timestamp}] #{entry}\n\n"

    File.write!(history_file, formatted, [:append])
  end

  @doc """
  Get memory context for system prompt (MEMORY.md content)
  """
  @spec get_memory_context() :: String.t()
  def get_memory_context do
    long_term = read_long_term()

    if long_term != "" do
      "## Long-term Memory\n\n#{long_term}"
    else
      ""
    end
  end

  @doc """
  Read HISTORY.md and parse into entries with timestamp and content.
  """
  @spec read_history() :: list(map())
  def read_history do
    history_file = Path.join(@memory_dir, "HISTORY.md")

    if File.exists?(history_file) do
      File.read!(history_file)
      |> String.split(~r/(?=\[)/, trim: true)
      |> Enum.map(fn entry ->
        case Regex.run(~r/^\[([^\]]+)\]\s*(.+)/s, String.trim(entry)) do
          [_, timestamp, content] ->
            date =
              case Date.from_iso8601(String.slice(timestamp, 0..9)) do
                {:ok, d} -> d
                _ -> nil
              end

            %{timestamp: timestamp, content: String.trim(content), date: date}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc """
  Read MEMORY.md and split into sections by `## ` headers.
  """
  @spec read_memory_sections() :: list(map())
  def read_memory_sections do
    memory_file = Path.join(@memory_dir, "MEMORY.md")

    if File.exists?(memory_file) do
      File.read!(memory_file)
      |> String.split(~r/(?=^## )/m, trim: true)
      |> Enum.filter(&String.starts_with?(&1, "## "))
      |> Enum.map(fn section ->
        [first_line | rest] = String.split(section, "\n", parts: 2)
        <<"## ", header_rest::binary>> = first_line
        header = String.trim(header_rest)
        content = if rest == [], do: "", else: hd(rest) |> String.trim()
        %{header: header, content: content}
      end)
    else
      []
    end
  end

  @doc """
  Consolidate old session messages into MEMORY.md and HISTORY.md via LLM.

  Takes messages beyond last_consolidated, asks LLM to summarize into
  a history entry + updated long-term memory. Updates session.last_consolidated.

  Returns {:ok, updated_session} or {:error, reason}.
  """
  @spec consolidate(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(session, provider, model, opts \\ []) do
    require Logger
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    memory_window = Keyword.get(opts, :memory_window, 50)

    messages = session.messages
    keep_count = div(memory_window, 2)
    total_len = length(messages)

    # Calculate how many messages to consolidate
    start_idx = session.last_consolidated
    end_idx = max(total_len - keep_count, start_idx)
    count = end_idx - start_idx

    old_messages =
      if count > 0 do
        Enum.slice(messages, start_idx, count)
      else
        []
      end

    if old_messages == [] do
      {:ok, session}
    else
      Logger.info("[Memory] Consolidating #{length(old_messages)} messages")

      # Cap messages to avoid sending too much to LLM
      old_messages =
        if length(old_messages) > 80 do
          Enum.take(old_messages, 10) ++ Enum.take(old_messages, -70)
        else
          old_messages
        end

      lines =
        old_messages
        |> Enum.reject(fn m -> is_nil(Map.get(m, "content")) end)
        |> Enum.map(fn m ->
          role = Map.get(m, "role", "?") |> String.upcase()
          content = Map.get(m, "content", "") |> to_string()
          max_len = if role == "TOOL", do: 100, else: 200
          "[#{role}]: #{String.slice(content, 0, max_len)}"
        end)
        |> Enum.join("\n")

      current_memory = read_long_term()

      memory_for_prompt =
        if byte_size(current_memory) > 2000 do
          String.slice(current_memory, 0, 2000) <> "\n... (truncated)"
        else
          current_memory
        end

      consolidation_prompt = """
      You are a memory consolidation agent. Process the conversation below and call the save_memory tool.

      Also identify any clear user preferences (language, communication style, coding conventions, workflow habits) visible in the conversation.
      Only report preferences that are clearly and consistently demonstrated — do not guess.

      ## Current Long-term Memory
      #{if memory_for_prompt == "", do: "(empty)", else: memory_for_prompt}

      ## Conversation to Process
      #{lines}
      """

      save_memory_tool = [
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
                },
                "user_preferences" => %{
                  "type" => "array",
                  "description" =>
                    "Optional: user preferences clearly demonstrated in this conversation. Only include if pattern is obvious.",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "field" => %{"type" => "string", "description" => "Preference name (e.g. 'Language', 'Code Style')"},
                      "value" => %{"type" => "string", "description" => "Preference value (e.g. 'Chinese', 'Functional style')"}
                    },
                    "required" => ["field", "value"]
                  }
                }
              },
              "required" => ["history_entry", "memory_update"]
            }
          }
        }
      ]

      consolidation_messages = [
        %{
          "role" => "system",
          "content" =>
            "You are a memory consolidation agent. Call the save_memory tool with your consolidation of the conversation."
        },
        %{"role" => "user", "content" => consolidation_prompt}
      ]

      llm_opts = [
        provider: provider,
        model: model,
        api_key: api_key,
        base_url: base_url,
        tools: save_memory_tool,
        tool_choice: tool_choice_for(provider, "save_memory")
      ]

      case Nex.Agent.Runner.call_llm_for_consolidation(consolidation_messages, llm_opts) do
        {:ok, result} when is_map(result) and map_size(result) > 0 ->
          handle_consolidation_result(result, session, messages, keep_count, current_memory)

        {:ok, empty} ->
          Logger.warning("[Memory] Consolidation returned empty result: #{inspect(empty)}, skipping")
          {:ok, session}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_consolidation_result(result, session, messages, keep_count, current_memory) do
    require Logger

    history_entry = Map.get(result, "history_entry")
    memory_update = Map.get(result, "memory_update")
    user_preferences = Map.get(result, "user_preferences")

    cond do
      not is_binary(history_entry) or String.trim(history_entry) == "" ->
        Logger.debug("[Memory] Consolidation skipped: missing history_entry")
        {:ok, session}

      not is_binary(memory_update) ->
        Logger.debug("[Memory] Consolidation skipped: missing memory_update")
        {:ok, session}

      true ->
        append_history(history_entry)

        if memory_update != current_memory && memory_update != "" do
          write_long_term(memory_update)
        end

        # Apply user preferences if present
        if is_list(user_preferences) and user_preferences != [] do
          Enum.each(user_preferences, fn pref ->
            field = pref["field"]
            value = pref["value"]

            if is_binary(field) and is_binary(value) do
              Nex.Agent.Reflection.apply_suggestion(%{
                type: :user_preference,
                name: field,
                action: value
              })

              Logger.info("[Memory] Learned user preference: #{field} = #{value}")
            end
          end)
        end

        new_last_consolidated = length(messages) - keep_count
        updated_session = %{session | last_consolidated: new_last_consolidated}
        Nex.Agent.SessionManager.save(updated_session)

        Logger.info("[Memory] Consolidation done, last_consolidated=#{new_last_consolidated}")
        {:ok, updated_session}
    end
  end

  defp tool_choice_for(:anthropic, name),
    do: %{"type" => "tool", "name" => name}

  defp tool_choice_for(_provider, name),
    do: %{"type" => "function", "function" => %{"name" => name}}
end
