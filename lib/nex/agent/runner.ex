defmodule Nex.Agent.Runner do
  @moduledoc false

  require Logger

  alias Nex.Agent.{
    Bus,
    ContextBuilder,
    Memory,
    Session,
    SessionManager
  }

  alias Nex.Agent.Tool.Registry, as: ToolRegistry

  @default_max_iterations 10
  @max_iterations_hard_limit 50
  @memory_window 50
  @max_tool_result_length 8000
  @tool_hint_preview_length 220
  @memory_nudge_interval 6
  @memory_flush_min_messages 12
  @skill_complexity_tool_calls 4
  @skill_complexity_tool_rounds 2
  @user_correction_terms [
    "actually",
    "instead",
    "that's wrong",
    "that is wrong",
    "不对",
    "应该",
    "改成",
    "不是这个"
  ]

  @doc """
  Run agent loop with session and prompt.
  """
  def run(session, prompt, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    workspace = Keyword.get(opts, :workspace)

    Logger.info("[Runner] Starting provider=#{provider} model=#{model}")

    session =
      if Keyword.get(opts, :skip_consolidation, false),
        do: session,
        else: maybe_consolidate_memory(session, provider, model, api_key, base_url, opts)

    initial_message_count = length(session.messages)
    {session, runtime_system_messages} = prepare_evolution_turn(session, prompt, opts)

    history_limit = Keyword.get(opts, :history_limit, @memory_window)
    history = Session.get_history(session, history_limit)

    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")
    media = Keyword.get(opts, :media)

    messages =
      ContextBuilder.build_messages(history, prompt, channel, chat_id, media,
        skip_skills: Keyword.get(opts, :skip_skills, false),
        workspace: workspace,
        runtime_system_messages: runtime_system_messages,
        cwd: Keyword.get(opts, :cwd)
      )

    session =
      Session.add_message(session, "user", prompt, project: Keyword.get(opts, :project))

    Logger.info("[Runner] LLM request: history=#{length(history)} messages=#{length(messages)}")

    opts =
      opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put_new(:_evolution_signals, default_evolution_signals())

    case run_loop(session, messages, 0, max_iterations, opts) do
      {:ok, result, final_session} ->
        {:ok, result,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace)}

      {:error, reason, final_session} ->
        {:error, reason,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace)}
    end
  end

  defp maybe_consolidate_memory(session, provider, model, api_key, base_url, opts) do
    workspace_opts = workspace_opts(opts)

    case SessionManager.start_consolidation(session.key, @memory_window, workspace_opts) do
      {:ok, consolidation_session, unconsolidated} ->
        Logger.info("[Runner] Triggering async memory consolidation: #{unconsolidated} messages")

        Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
          result =
            try do
              _ =
                maybe_flush_memory_before_consolidation(
                  consolidation_session,
                  provider,
                  model,
                  api_key,
                  base_url,
                  opts
                )

              Memory.consolidate(consolidation_session, provider, model,
                api_key: api_key,
                base_url: base_url,
                memory_window: @memory_window,
                workspace: Keyword.get(opts, :workspace),
                req_llm_generate_text_fun: Keyword.get(opts, :req_llm_generate_text_fun)
              )
            rescue
              error ->
                {:error, {:exception, Exception.message(error)}}
            catch
              kind, reason ->
                {:error, {kind, reason}}
            end

          case result do
            {:ok, updated_session} ->
              SessionManager.finish_consolidation(updated_session, workspace_opts)

              Logger.info(
                "[Runner] Async memory consolidation saved last_consolidated=#{updated_session.last_consolidated}"
              )

            {:error, reason} ->
              SessionManager.cancel_consolidation(consolidation_session.key, workspace_opts)
              Logger.warning("[Runner] Async memory consolidation failed: #{inspect(reason)}")
          end
        end)

        consolidation_session

      :already_running ->
        Logger.debug("[Runner] Skipping memory consolidation: already in progress")
        session

      :below_threshold ->
        session
    end
  end

  defp prepare_evolution_turn(session, prompt, _opts) do
    metadata = evolution_metadata(session)
    turns_since_memory = metadata["turns_since_memory_write"] || 0
    turns_for_this_request = turns_since_memory + 1
    pending_skill_nudge = metadata["pending_skill_nudge"] == true

    runtime_system_messages =
      []
      |> maybe_add_memory_nudge(turns_for_this_request)
      |> maybe_add_skill_nudge(pending_skill_nudge)

    updated_metadata =
      metadata
      |> Map.put("turns_since_memory_write", turns_for_this_request)
      |> Map.put("pending_skill_nudge", false)
      |> Map.put("last_prompt", prompt)

    {put_evolution_metadata(session, updated_metadata), runtime_system_messages}
  end

  defp finalize_evolution_turn(session, initial_message_count, prompt, workspace) do
    delta_messages = Enum.drop(session.messages, initial_message_count)
    signals = collect_evolution_signals(delta_messages, prompt)
    metadata = evolution_metadata(session)
    wrote_memory = signals.wrote_memory
    created_skill = signals.created_skill

    updated_metadata =
      metadata
      |> Map.put(
        "turns_since_memory_write",
        if(wrote_memory, do: 0, else: Map.get(metadata, "turns_since_memory_write", 0))
      )
      |> Map.put("last_complex_task", signals.complex_task)
      |> Map.put("last_tool_call_count", signals.tool_call_count)
      |> Map.put("last_tool_rounds", signals.tool_rounds)
      |> Map.put(
        "pending_skill_nudge",
        signals.complex_task and not created_skill
      )

    # Record evolution signals for the Evolution module
    maybe_record_evolution_signal(signals, prompt, workspace)

    put_evolution_metadata(session, updated_metadata)
  end

  defp maybe_record_evolution_signal(signals, prompt, workspace) do
    if signals.correction_hint or signals.tool_errors > 0 do
      Nex.Agent.Evolution.record_signal(
        %{
          source: "runner",
          signal:
            cond do
              signals.correction_hint and signals.tool_errors > 0 ->
                "User correction with #{signals.tool_errors} tool error(s): #{String.slice(prompt, 0, 200)}"

              signals.correction_hint ->
                "User correction: #{String.slice(prompt, 0, 200)}"

              true ->
                "#{signals.tool_errors} tool error(s) during: #{String.slice(prompt, 0, 200)}"
            end,
          context: %{
            tool_errors: signals.tool_errors,
            correction: signals.correction_hint,
            tools_used: signals.used_tools |> Enum.uniq()
          }
        },
        workspace: workspace
      )
    end
  end

  defp maybe_add_memory_nudge(messages, turns_since_memory_write) do
    if turns_since_memory_write >= @memory_nudge_interval and
         rem(turns_since_memory_write, @memory_nudge_interval) == 0 do
      messages ++
        [
          "[Runtime Evolution Nudge] Several exchanges have passed without a memory update. " <>
            "If this session revealed durable user profile facts, use user_update. " <>
            "If it revealed durable environment or project conventions, use memory_write."
        ]
    else
      messages
    end
  end

  defp maybe_add_skill_nudge(messages, true) do
    messages ++
      [
        "[Runtime Evolution Nudge] The previous task was complex. If you discovered a reusable workflow, troubleshooting path, or corrected multi-step procedure, decide whether to save it with skill_create."
      ]
  end

  defp maybe_add_skill_nudge(messages, _), do: messages

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    iter_start = System.monotonic_time(:millisecond)
    Logger.info("[Runner] === Iteration #{iteration + 1}/#{max_iterations} started ===")
    on_progress = Keyword.get(opts, :on_progress)

    if iteration >= max_iterations do
      Logger.warning("[Runner] Max iterations reached (#{max_iterations})")
      {:error, :max_iterations_exceeded, session}
    else
      # Time the LLM call
      llm_start = System.monotonic_time(:millisecond)

      llm_result =
        try do
          call_llm_with_retry(messages, opts, _retries = 1)
        rescue
          e ->
            Logger.error("[Runner] LLM call crashed: #{Exception.message(e)}")
            {:error, "LLM call failed: #{Exception.message(e)}"}
        catch
          kind, reason ->
            Logger.error("[Runner] LLM call crashed: #{kind} #{inspect(reason)}")
            {:error, "LLM call failed: #{kind} #{inspect(reason)}"}
        end

      llm_duration = System.monotonic_time(:millisecond) - llm_start
      Logger.info("[Runner] LLM call took #{llm_duration}ms")

      case llm_result do
        {:ok, response} ->
          content = response.content
          finish_reason = Map.get(response, :finish_reason)

          reasoning_content =
            Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content")

          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if finish_reason == "error" do
            # Nanobot parity: keep the user turn, but never persist the assistant error response.
            Logger.error("[Runner] LLM returned error finish_reason")
            iter_total = System.monotonic_time(:millisecond) - iter_start

            Logger.info(
              "[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms (error) ==="
            )

            {:error, "LLM returned an error", session}
          else
            result =
              handle_response(
                session,
                messages,
                content,
                tool_calls,
                reasoning_content,
                iteration,
                max_iterations,
                on_progress,
                opts
              )

            iter_total = System.monotonic_time(:millisecond) - iter_start
            Logger.info("[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms ===")
            result
          end

        {:error, reason} ->
          Logger.error("[Runner] LLM call failed: #{inspect(reason)}")
          iter_total = System.monotonic_time(:millisecond) - iter_start

          Logger.info(
            "[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms (failed) ==="
          )

          {:error, reason, session}
      end
    end
  end

  @max_loop_repeats 3

  defp handle_response(
         session,
         messages,
         content,
         tool_calls,
         reasoning_content,
         iteration,
         max_iterations,
         on_progress,
         opts
       )
       when is_list(tool_calls) and tool_calls != [] do
    Logger.info("[Runner] LLM requests #{length(tool_calls)} tool call(s)")

    tool_call_dicts = normalize_tool_calls(tool_calls)

    current_signatures =
      tool_call_dicts
      |> Enum.map(fn tc ->
        name = get_in(tc, ["function", "name"])
        args = get_in(tc, ["function", "arguments"]) || ""
        {name, tool_loop_signature(name, args)}
      end)
      |> Enum.sort()

    tool_history = Keyword.get(opts, :_tool_history, [])
    tool_history = [current_signatures | tool_history] |> Enum.take(@max_loop_repeats)

    # Detect loop: exact same {tool_name, args} pattern repeated N times consecutively
    if length(tool_history) >= @max_loop_repeats and
         tool_history |> Enum.take(@max_loop_repeats) |> Enum.uniq() |> length() == 1 do
      Logger.warning(
        "[Runner] Loop detected: #{inspect(current_signatures)} repeated #{@max_loop_repeats}x, breaking"
      )

      {:ok,
       render_text(content) ||
         "I detected a repeated action loop and stopped. Please try a different approach.",
       session}
    else
      opts = Keyword.put(opts, :_tool_history, tool_history)

      maybe_send_progress(on_progress, content, tool_call_dicts)

      messages =
        ContextBuilder.add_assistant_message(
          messages,
          content,
          tool_call_dicts,
          reasoning_content
        )

      session =
        Session.add_message(session, "assistant", content,
          tool_calls: tool_call_dicts,
          reasoning_content: reasoning_content
        )

      {new_messages, results, session, opts} =
        execute_tools(session, messages, tool_call_dicts, opts)

      maybe_publish_tool_results(results, opts)

      message_sent_to_current_channel =
        Enum.any?(results, fn {_id, name, _r, args} ->
          name == "message" and message_targets_current_conversation?(args, opts)
        end)

      effective_max =
        if iteration + 1 >= max_iterations and iteration + 1 < @max_iterations_hard_limit and
             not Keyword.has_key?(opts, :tools_filter) and
             not Keyword.get(opts, :_expanded, false) do
          new_max = min(max_iterations * 2, @max_iterations_hard_limit)
          Logger.info("[Runner] Auto-expanding max_iterations #{max_iterations} -> #{new_max}")
          new_max
        else
          max_iterations
        end

      opts =
        if effective_max > max_iterations,
          do: Keyword.put(opts, :_expanded, true),
          else: opts

      case run_loop(session, new_messages, iteration + 1, effective_max, opts) do
        {:ok, _final_content, final_session} when message_sent_to_current_channel ->
          {:ok, :message_sent, final_session}

        other ->
          other
      end
    end
  end

  defp handle_response(
         session,
         _messages,
         content,
         _tool_calls,
         reasoning_content,
         _iteration,
         _max_iterations,
         _on_progress,
         _opts
       ) do
    content_text = render_text(content)

    Logger.info("[Runner] LLM finished: #{String.slice(content_text, 0, 100)}")

    session =
      Session.add_message(session, "assistant", content_text,
        reasoning_content: reasoning_content
      )

    {:ok, content_text, session}
  end

  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

      name =
        Map.get(tc, :name) || Map.get(tc, "name") || Map.get(func, "name") ||
          Map.get(func, :name)

      arguments =
        Map.get(tc, :arguments) || Map.get(tc, "arguments") ||
          Map.get(func, "arguments") || Map.get(func, :arguments) || %{}

      %{
        "id" => Map.get(tc, :id) || Map.get(tc, "id") || generate_tool_call_id(),
        "type" => "function",
        "function" => %{
          "name" => name,
          "arguments" => if(is_binary(arguments), do: arguments, else: Jason.encode!(arguments))
        }
      }
    end)
  end

  defp maybe_send_progress(nil, _content, _tool_calls), do: :ok

  defp maybe_send_progress(on_progress, content, tool_call_dicts) do
    hint = format_tool_hint(tool_call_dicts)

    if is_function(on_progress, 2) do
      on_progress.(:tool_hint, hint)
    end

    clean = strip_think_tags(content)

    if clean && clean != "" && is_function(on_progress, 2) do
      on_progress.(:thinking, clean)
    end

    :ok
  end

  defp format_tool_hint(tool_call_dicts) do
    Enum.map_join(tool_call_dicts, ", ", fn tc ->
      name = get_in(tc, ["function", "name"]) || "?"
      args = get_in(tc, ["function", "arguments"]) || ""

      args_preview =
        args
        |> normalize_tool_hint_args(name)
        |> truncate_tool_hint(@tool_hint_preview_length)

      "#{name}(#{args_preview})"
    end)
  end

  defp normalize_tool_hint_args(args, tool_name) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> normalize_tool_hint_args(decoded, tool_name)
      _ -> args
    end
  end

  defp normalize_tool_hint_args(%{"command" => command}, "bash") when is_binary(command),
    do: command

  defp normalize_tool_hint_args(%{command: command}, "bash") when is_binary(command), do: command

  defp normalize_tool_hint_args(args, _tool_name) when is_map(args) do
    inspect(args, limit: :infinity, printable_limit: 500)
  end

  defp normalize_tool_hint_args(args, _tool_name), do: render_text(args)

  defp truncate_tool_hint(text, max_len) when is_binary(text) and byte_size(text) > max_len do
    String.slice(text, 0, max_len - 3) <> "..."
  end

  defp truncate_tool_hint(text, _max_len), do: text

  defp strip_think_tags(nil), do: nil

  defp strip_think_tags(content) do
    content
    |> render_text()
    |> String.replace(~r/<think>.*?<\/think>/s, "")
    |> String.trim()
  end

  defp maybe_publish_tool_results(results, opts) do
    if Process.whereis(Nex.Agent.Bus) do
      Enum.each(results, fn {_id, tool_name, result, args} ->
        success = not String.starts_with?(render_text(result), "Error")

        Bus.publish(:tool_result, %{
          tool: tool_name,
          success: success,
          result: truncate_result(result),
          args: summarize_args(tool_name, args),
          channel: Keyword.get(opts, :channel),
          chat_id: Keyword.get(opts, :chat_id)
        })
      end)
    end
  end

  defp truncate_result(result)
       when is_binary(result) and byte_size(result) > @max_tool_result_length do
    String.slice(result, 0, @max_tool_result_length) <> "\n... (truncated)"
  end

  defp truncate_result(result) when is_binary(result), do: result
  defp truncate_result(result), do: inspect(result)

  defp summarize_args("bash", %{"command" => cmd}) when is_binary(cmd), do: %{"command" => cmd}
  defp summarize_args("bash", %{command: cmd}) when is_binary(cmd), do: %{"command" => cmd}

  defp summarize_args(_tool_name, args) when is_map(args) do
    args
    |> Enum.take(3)
    |> Map.new(fn {k, v} ->
      v_str = if is_binary(v), do: String.slice(v, 0, 100), else: inspect(v, limit: 3)
      {to_string(k), v_str}
    end)
  end

  defp summarize_args(_tool_name, _args), do: %{}

  defp message_targets_current_conversation?(args, opts) do
    current_channel = Keyword.get(opts, :channel)

    if is_binary(current_channel) do
      message_targets_current_conversation_with_channel?(args, opts, current_channel)
    else
      false
    end
  end

  defp message_targets_current_conversation_with_channel?(args, opts, current_channel)
       when is_map(args) do
    current_chat_id = normalize_chat_id(Keyword.get(opts, :chat_id))

    target_channel =
      Map.get(args, "channel") || Map.get(args, :channel) || current_channel

    target_chat_id =
      Map.get(args, "chat_id") || Map.get(args, :chat_id) || current_chat_id

    target_channel == current_channel and normalize_chat_id(target_chat_id) == current_chat_id
  end

  defp message_targets_current_conversation_with_channel?(_args, _opts, _current_channel),
    do: false

  defp normalize_chat_id(nil), do: ""
  defp normalize_chat_id(chat_id), do: to_string(chat_id)

  defp call_llm_with_retry(messages, opts, retries_left) do
    case call_llm(messages, opts) do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        cond do
          retries_left > 0 and transient_error?(reason) ->
            Logger.warning("[Runner] LLM transient error, retrying in 2s: #{inspect(reason)}")
            Process.sleep(2_000)
            call_llm_with_retry(messages, opts, retries_left - 1)

          not Keyword.get(opts, :__recovered, false) ->
            case attempt_recovery(reason, messages, opts) do
              {:retry, new_messages, new_opts} ->
                new_opts = Keyword.put(new_opts, :__recovered, true)
                call_llm_with_retry(new_messages, new_opts, 0)

              :give_up ->
                error
            end

          true ->
            error
        end
    end
  end

  # Analyze LLM error and attempt automatic recovery.
  defp attempt_recovery(reason, messages, opts) do
    error_msg = extract_error_message(reason)
    status = extract_error_status(reason)

    cond do
      # 400: context too long → trim older messages
      status == 400 and context_length_error?(error_msg) ->
        trimmed = trim_messages(messages)

        if length(trimmed) < length(messages) do
          Logger.warning(
            "[Runner] Context too long (#{length(messages)} msgs), trimmed to #{length(trimmed)}"
          )

          {:retry, trimmed, opts}
        else
          :give_up
        end

      # 400: other known patterns can be added here
      true ->
        :give_up
    end
  end

  defp extract_error_message(%{error: %{"error" => %{"message" => msg}}}), do: msg
  defp extract_error_message(%{error: %{message: msg}}), do: msg
  defp extract_error_message(msg) when is_binary(msg), do: msg
  defp extract_error_message(other), do: inspect(other)

  defp extract_error_status(%{status: status}), do: status
  defp extract_error_status(_), do: nil

  defp context_length_error?(msg) do
    String.contains?(msg, "context_length") or
      String.contains?(msg, "too long") or
      String.contains?(msg, "maximum context") or
      String.contains?(msg, "token")
  end

  # Trim messages by removing older turns, keeping system + first user + recent messages.
  defp trim_messages(messages) when length(messages) <= 4, do: messages

  defp trim_messages(messages) do
    # Keep first 2 messages (system prompt + first user) and last half
    keep_recent = max(div(length(messages), 2), 4)
    first = Enum.take(messages, 2)
    recent = Enum.take(messages, -keep_recent)
    Enum.uniq(first ++ recent)
  end

  defp transient_error?(%{__struct__: struct}) do
    struct_name = to_string(struct)
    String.contains?(struct_name, "TransportError") or String.contains?(struct_name, "Mint")
  end

  defp transient_error?(%{status: status}) when status in [429, 500, 502, 503, 504], do: true
  defp transient_error?(:timeout), do: true
  defp transient_error?(:closed), do: true
  defp transient_error?(reason) when is_binary(reason), do: String.contains?(reason, "timeout")
  defp transient_error?(_), do: false

  defp call_llm(messages, opts) do
    tools =
      case Keyword.get(opts, :tools_filter) do
        :subagent -> registry_definitions(:subagent)
        :cron -> registry_definitions(:cron)
        _ -> registry_definitions(:all)
      end

    opts = Keyword.put(opts, :tools, tools)

    if opts[:llm_client] do
      opts[:llm_client].(messages, opts)
    else
      call_llm_real(messages, opts)
    end
  end

  # Tool names must start with a letter and contain only letters, numbers, underscores, dashes.
  @valid_tool_name ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/

  defp registry_definitions(filter) do
    if Process.whereis(ToolRegistry) do
      ToolRegistry.definitions(filter)
      |> Enum.filter(fn tool ->
        name = tool["name"]

        if valid_tool_name?(name) do
          true
        else
          Logger.warning("[Runner] Dropping tool with invalid name: #{inspect(name)}")
          false
        end
      end)
      |> Enum.uniq_by(& &1["name"])
    else
      []
    end
  end

  defp valid_tool_name?(name) when is_binary(name), do: Regex.match?(@valid_tool_name, name)
  defp valid_tool_name?(_), do: false

  defp call_llm_real(messages, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)

    [
      provider: provider,
      model: Keyword.get(opts, :model),
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      tools: Keyword.get(opts, :tools, []),
      temperature: Keyword.get(opts, :temperature, 1.0),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      tool_choice: Keyword.get(opts, :tool_choice)
    ]
    |> maybe_put_opt(:req_llm_generate_text_fun, Keyword.get(opts, :req_llm_generate_text_fun))
    |> then(&Nex.Agent.LLM.ReqLLM.chat(messages, &1))
  end

  defp execute_tools(session, messages, tool_calls, opts) do
    ctx = build_tool_ctx(opts)

    # Pre-extract tool metadata before async execution so it survives task crashes
    indexed_calls =
      Enum.map(tool_calls, fn tc ->
        func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

        tool_name =
          Map.get(tc, :name) || Map.get(tc, "name") || Map.get(func, "name") ||
            Map.get(func, :name)

        tool_call_id = Map.get(tc, :id) || Map.get(tc, "id") || generate_tool_call_id()

        args =
          Map.get(tc, :arguments) || Map.get(tc, "arguments") || Map.get(func, "arguments") ||
            Map.get(func, :arguments) || %{}

        {tool_call_id, tool_name, args}
      end)

    results =
      indexed_calls
      |> Task.async_stream(
        fn {tool_call_id, tool_name, args} ->
          parsed_args = parse_args(args)
          Logger.info("[Runner] Executing tool: #{tool_name}(#{inspect(parsed_args)})")

          result = execute_tool(tool_name, parsed_args, ctx)
          truncated = truncate_result(result)

          {tool_call_id, tool_name, truncated, parsed_args}
        end,
        ordered: true,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(indexed_calls)
      |> Enum.map(fn
        {{:ok, result}, _meta} ->
          result

        {{:exit, reason}, {tool_call_id, tool_name, args}} ->
          Logger.error("[Runner] Tool task exited: #{tool_name} #{inspect(reason)}")

          {tool_call_id, tool_name, "Error: tool timed out or crashed (#{inspect(reason)})",
           parse_args(args)}
      end)

    {new_messages, session} =
      Enum.reduce(results, {messages, session}, fn {tool_call_id, tool_name, result, _args},
                                                   {msgs, sess} ->
        msgs = ContextBuilder.add_tool_result(msgs, tool_call_id, tool_name, result)

        sess =
          Session.add_message(sess, "tool", result, tool_call_id: tool_call_id, name: tool_name)

        {msgs, sess}
      end)

    {new_messages, results, session, update_evolution_signals(opts, results)}
  end

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} ->
        map

      _ ->
        case Nex.Agent.LLM.JsonRepair.repair_and_decode(args) do
          {:ok, map} -> map
          _ -> %{}
        end
    end
  end

  defp parse_args([head | _rest]) when is_map(head), do: head
  defp parse_args([]), do: %{}
  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}

  defp tool_loop_signature("tool_create", args) do
    parsed = parse_args(args)
    Map.get(parsed, "name") || Map.get(parsed, :name) || args
  end

  defp tool_loop_signature(_name, args), do: args

  @doc false
  def parse_tool_arguments(args), do: parse_args(args)

  defp execute_tool(tool_name, args, ctx) do
    if Process.whereis(ToolRegistry) do
      case ToolRegistry.execute(tool_name, args, ctx) do
        {:ok, result} when is_binary(result) ->
          result

        {:ok, %{content: content}} when is_binary(content) ->
          content

        {:ok, %{error: error}} ->
          "Error: #{error}"

        {:ok, result} when is_map(result) ->
          Jason.encode!(result, pretty: true)

        {:ok, result} ->
          render_text(result)

        {:error, reason} ->
          "Error: #{reason}"
      end
    else
      "Error: tool registry unavailable"
    end
  end

  defp build_tool_ctx(opts) do
    %{
      channel: Keyword.get(opts, :channel),
      chat_id: Keyword.get(opts, :chat_id),
      session_key: Keyword.get(opts, :session_key),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      tools: Keyword.get(opts, :tools, %{}),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      workspace: Keyword.get(opts, :workspace),
      project: Keyword.get(opts, :project),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  @doc """
  Call LLM for memory consolidation - exposes for Memory module.
  """
  def call_llm_for_consolidation(messages, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)
    tool_choice = Keyword.get(opts, :tool_choice)

    call_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        tools: Keyword.get(opts, :tools, []),
        tool_choice: tool_choice
      ]
      |> maybe_put_opt(:req_llm_generate_text_fun, Keyword.get(opts, :req_llm_generate_text_fun))

    case Nex.Agent.LLM.ReqLLM.chat(messages, call_opts) do
      {:ok, response} ->
        extract_tool_call(response)

      {:error, err} ->
        case consolidation_tool_choice_retry_reason(provider, tool_choice, err) do
          nil ->
            {:error, err}

          reason ->
            Logger.warning("[Runner] #{consolidation_tool_choice_retry_message(reason)}")
            retry_opts = Keyword.delete(call_opts, :tool_choice)

            case Nex.Agent.LLM.ReqLLM.chat(messages, retry_opts) do
              {:ok, response} -> extract_tool_call(response)
              error -> error
            end
        end

      error ->
        error
    end
  end

  defp extract_tool_call(response) do
    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

    if is_list(tool_calls) and tool_calls != [] do
      tc = List.first(tool_calls)
      func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

      args =
        Map.get(tc, :arguments) || Map.get(tc, "arguments") || Map.get(func, "arguments") ||
          Map.get(func, :arguments) || %{}

      args = parse_args(args)

      {:ok, args}
    else
      {:error, "No tool call in response"}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp consolidation_tool_choice_retry_reason(_provider, nil, _err), do: nil

  defp consolidation_tool_choice_retry_reason(provider, _tool_choice, err) do
    err_msg = err |> inspect() |> String.downcase()

    cond do
      String.contains?(err_msg, "tool_choice") ->
        :tool_choice_incompatible

      provider == :anthropic and
        String.contains?(err_msg, "matcherror") and
          String.contains?(err_msg, "not_implemented") ->
        :anthropic_match_error

      true ->
        nil
    end
  end

  defp consolidation_tool_choice_retry_message(:tool_choice_incompatible) do
    "tool_choice incompatible, retrying without it"
  end

  defp consolidation_tool_choice_retry_message(:anthropic_match_error) do
    "Anthropic tool_choice fallback triggered after MatchError, retrying without it"
  end

  defp default_evolution_signals do
    %{
      tool_call_count: 0,
      tool_rounds: 0,
      tool_errors: 0,
      used_tools: []
    }
  end

  defp update_evolution_signals(opts, results) do
    current = Keyword.get(opts, :_evolution_signals, default_evolution_signals())

    tool_errors =
      Enum.count(results, fn {_id, _name, result, _args} ->
        String.starts_with?(result, "Error:")
      end)

    used_tools = Enum.map(results, fn {_id, name, _result, _args} -> name end)

    Keyword.put(opts, :_evolution_signals, %{
      tool_call_count: current.tool_call_count + length(results),
      tool_rounds: current.tool_rounds + if(results == [], do: 0, else: 1),
      tool_errors: current.tool_errors + tool_errors,
      used_tools: current.used_tools ++ used_tools
    })
  end

  defp evolution_metadata(session) do
    Map.get(session.metadata || %{}, "runtime_evolution", %{})
  end

  defp put_evolution_metadata(session, metadata) do
    %{session | metadata: Map.put(session.metadata || %{}, "runtime_evolution", metadata)}
  end

  defp collect_evolution_signals(delta_messages, prompt) do
    tool_messages = Enum.filter(delta_messages, &(Map.get(&1, "role") == "tool"))
    tool_call_count = length(tool_messages)
    used_tools = Enum.map(tool_messages, &Map.get(&1, "name"))

    tool_rounds =
      delta_messages
      |> Enum.filter(&(Map.get(&1, "role") == "assistant" and is_list(Map.get(&1, "tool_calls"))))
      |> length()

    tool_errors =
      tool_messages
      |> Enum.count(fn msg ->
        msg
        |> Map.get("content", "")
        |> render_text()
        |> String.starts_with?("Error:")
      end)

    correction_hint =
      prompt
      |> String.downcase()
      |> then(fn lowered -> Enum.any?(@user_correction_terms, &String.contains?(lowered, &1)) end)

    %{
      wrote_memory: "memory_write" in used_tools,
      created_skill: "skill_create" in used_tools,
      used_tools: used_tools,
      tool_call_count: tool_call_count,
      tool_rounds: tool_rounds,
      tool_errors: tool_errors,
      correction_hint: correction_hint,
      complex_task:
        tool_call_count >= @skill_complexity_tool_calls or
          tool_rounds >= @skill_complexity_tool_rounds or
          tool_errors > 0 or correction_hint
    }
  end

  defp maybe_flush_memory_before_consolidation(session, provider, model, api_key, base_url, opts) do
    unconsolidated = length(session.messages) - session.last_consolidated

    if unconsolidated < @memory_flush_min_messages do
      :ok
    else
      lines =
        session.messages
        |> Enum.drop(session.last_consolidated)
        |> Enum.take(-@memory_window)
        |> Enum.map(fn msg ->
          role = Map.get(msg, "role", "unknown")
          content = Map.get(msg, "content", "") |> render_text()
          "[#{role}] #{content}"
        end)
        |> Enum.reject(&(&1 == "[unknown] "))

      if lines == [] do
        :ok
      else
        prompt = """
        Review this conversation excerpt before archival. If it contains one durable fact worth saving,
        call memory_write exactly once with action=append or action=set for durable project/environment/workflow knowledge.
        Do not write user profile facts here. If nothing is worth saving, do not call any tool.

        ## USER.md
        #{Memory.read_user_profile(workspace: Keyword.get(opts, :workspace))}

        ## MEMORY.md
        #{Memory.read_long_term(workspace: Keyword.get(opts, :workspace))}

        ## Recent Conversation
        #{Enum.join(lines, "\n")}
        """

        messages = [
          %{
            "role" => "system",
            "content" =>
              "You are a memory flush agent. Only call memory_write when the conversation contains durable long-term knowledge worth saving."
          },
          %{"role" => "user", "content" => prompt}
        ]

        case call_llm_for_consolidation(messages,
               provider: provider,
               model: model,
               api_key: api_key,
               base_url: base_url,
               tools: [
                 %{
                   "type" => "function",
                   "function" => Nex.Agent.Tool.MemoryWrite.definition()
                 }
               ],
               tool_choice: tool_choice_for_memory_write(provider),
               req_llm_generate_text_fun: Keyword.get(opts, :req_llm_generate_text_fun)
             ) do
          {:ok, %{} = args} when map_size(args) > 0 ->
            _ =
              Memory.apply_memory_write(
                Map.get(args, "action"),
                "memory",
                Map.get(args, "content"),
                workspace: Keyword.get(opts, :workspace)
              )

            :ok

          _ ->
            :ok
        end
      end
    end
  end

  defp render_text(nil), do: ""
  defp render_text(text) when is_binary(text), do: text

  defp render_text(text) when is_atom(text) or is_integer(text) or is_float(text),
    do: to_string(text)

  defp render_text(content) when is_list(content) do
    cond do
      List.ascii_printable?(content) ->
        to_string(content)

      Enum.all?(content, &text_content_part?/1) ->
        Enum.map_join(content, "", fn
          %{"type" => "text", "text" => text} -> text
          %{type: "text", text: text} -> text
          text when is_binary(text) -> text
        end)

      true ->
        render_structured(content)
    end
  end

  defp render_text(content) when is_map(content), do: render_structured(content)
  defp render_text(content), do: inspect(content, printable_limit: 500, limit: 50)

  defp text_content_part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp text_content_part?(%{type: "text", text: text}) when is_binary(text), do: true
  defp text_content_part?(text) when is_binary(text), do: true
  defp text_content_part?(_), do: false

  defp render_structured(content) do
    case Jason.encode(content, pretty: true) do
      {:ok, encoded} -> encoded
      _ -> inspect(content, printable_limit: 500, limit: 50)
    end
  end

  defp tool_choice_for_memory_write(:anthropic), do: %{type: "tool", name: "memory_write"}

  defp tool_choice_for_memory_write(_provider),
    do: %{type: "function", function: %{name: "memory_write"}}

  defp workspace_opts(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end
end
