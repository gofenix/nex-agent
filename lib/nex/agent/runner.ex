defmodule Nex.Agent.Runner do
  require Logger

  alias Nex.Agent.{
    Bus,
    Session,
    ContextBuilder,
    Skills,
    Memory
  }

  alias Nex.Agent.Tool.Registry, as: ToolRegistry

  @default_max_iterations 10
  @max_iterations_hard_limit 50
  @memory_window 100
  @max_tool_result_length 2000
  @tool_hint_preview_length 220

  @doc """
  Run agent loop with session and prompt.
  """
  def run(session, prompt, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)

    Logger.info("[Runner] Starting provider=#{provider} model=#{model}")

    session = maybe_consolidate_memory(session, provider, model, api_key, base_url)

    history = Session.get_history(session, @memory_window)

    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")

    messages =
      ContextBuilder.build_messages(history, prompt, channel, chat_id)

    session = Session.add_message(session, "user", prompt)

    Logger.info("[Runner] LLM request: history=#{length(history)} messages=#{length(messages)}")

    run_loop(session, messages, 0, max_iterations, opts)
  end

  defp maybe_consolidate_memory(session, provider, model, api_key, base_url) do
    messages = session.messages
    unconsolidated = length(messages) - session.last_consolidated

    if unconsolidated >= @memory_window do
      Logger.info("[Runner] Triggering async memory consolidation: #{unconsolidated} messages")

      Task.start(fn ->
        Memory.consolidate(session, provider, model,
          api_key: api_key,
          base_url: base_url,
          memory_window: @memory_window
        )
      end)

      session
    else
      session
    end
  end

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    Logger.debug("[Runner] Loop iteration=#{iteration + 1}/#{max_iterations}")
    on_progress = Keyword.get(opts, :on_progress)

    if iteration >= max_iterations do
      Logger.warning("[Runner] Max iterations reached (#{max_iterations})")
      {:error, :max_iterations_exceeded, session}
    else
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

      case llm_result do
        {:ok, response} ->
          content = response.content
          finish_reason = Map.get(response, :finish_reason)

          reasoning_content =
            Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content")

          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if finish_reason == "error" do
            Logger.error("[Runner] LLM returned error finish_reason")
            {:error, "LLM returned an error", session}
          else
            handle_response(session, messages, content, tool_calls, reasoning_content,
              iteration, max_iterations, on_progress, opts)
          end

        {:error, reason} ->
          Logger.error("[Runner] LLM call failed: #{inspect(reason)}")
          {:error, reason, session}
      end
    end
  end

  defp handle_response(session, messages, content, tool_calls, reasoning_content,
         iteration, max_iterations, on_progress, opts)
       when is_list(tool_calls) and tool_calls != [] do
    Logger.info("[Runner] LLM requests #{length(tool_calls)} tool call(s)")

    tool_call_dicts = normalize_tool_calls(tool_calls)

    maybe_send_progress(on_progress, content, tool_call_dicts)

    messages =
      ContextBuilder.add_assistant_message(messages, content, tool_call_dicts, reasoning_content)

    session =
      Session.add_message(session, "assistant", content,
        tool_calls: tool_call_dicts,
        reasoning_content: reasoning_content
      )

    {new_messages, results, session} = execute_tools(session, messages, tool_calls, opts)

    maybe_publish_tool_results(results, opts)

    # Check if message tool was used
    message_sent = Enum.any?(results, fn {_id, name, _r} -> name == "message" end)

    effective_max =
      if iteration + 1 >= max_iterations and iteration + 1 < @max_iterations_hard_limit do
        new_max = min(max_iterations * 2, @max_iterations_hard_limit)
        Logger.info("[Runner] Auto-expanding max_iterations #{max_iterations} -> #{new_max}")
        new_max
      else
        max_iterations
      end

    case run_loop(session, new_messages, iteration + 1, effective_max, opts) do
      {:ok, final_content, final_session} when message_sent and (final_content == "" or is_nil(final_content)) ->
        {:ok, :message_sent, final_session}

      other ->
        other
    end
  end

  defp handle_response(session, _messages, content, _tool_calls, reasoning_content,
         _iteration, _max_iterations, _on_progress, _opts) do
    Logger.info("[Runner] LLM finished: #{String.slice(content || "", 0, 100)}")

    session =
      Session.add_message(session, "assistant", content || "",
        reasoning_content: reasoning_content
      )

    {:ok, content || "", session}
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
          "arguments" =>
            if(is_binary(arguments), do: arguments, else: Jason.encode!(arguments))
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

  defp normalize_tool_hint_args(args, _tool_name), do: to_string(args)

  defp truncate_tool_hint(text, max_len) when is_binary(text) and byte_size(text) > max_len do
    String.slice(text, 0, max_len - 3) <> "..."
  end

  defp truncate_tool_hint(text, _max_len), do: text

  defp strip_think_tags(nil), do: nil

  defp strip_think_tags(content) do
    content
    |> String.replace(~r/<think>.*?<\/think>/s, "")
    |> String.trim()
  end

  defp maybe_publish_tool_results(results, opts) do
    if Process.whereis(Nex.Agent.Bus) do
      Enum.each(results, fn {_id, tool_name, result} ->
        success = not String.starts_with?(to_string(result), "Error")

        Bus.publish(:tool_result, %{
          tool: tool_name,
          success: success,
          result: truncate_result(result),
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

  defp call_llm_with_retry(messages, opts, retries_left) do
    case call_llm(messages, opts) do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        if retries_left > 0 and transient_error?(reason) do
          Logger.warning("[Runner] LLM transient error, retrying in 2s: #{inspect(reason)}")
          Process.sleep(2_000)
          call_llm_with_retry(messages, opts, retries_left - 1)
        else
          error
        end
    end
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
        _ -> registry_definitions(:all)
      end

    opts = Keyword.put(opts, :tools, tools)

    if opts[:llm_client] do
      opts[:llm_client].(messages, opts)
    else
      call_llm_real(messages, opts)
    end
  end

  defp registry_definitions(filter) do
    if Process.whereis(ToolRegistry) do
      registry_defs = ToolRegistry.definitions(filter)

      # Also include dynamic skill tools
      skill_tools =
        Skills.for_llm()
        |> Enum.map(fn skill ->
          name = Map.get(skill, "name") || Map.get(skill, :name)
          desc = Map.get(skill, "description") || Map.get(skill, :description)

          %{
            "name" => name,
            "description" => desc,
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "input" => %{"type" => "string", "description" => "Input to skill"}
              },
              "required" => ["input"]
            }
          }
        end)

      registry_defs ++ skill_tools
    else
      []
    end
  end

  defp call_llm_real(messages, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model)
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    tools = Keyword.get(opts, :tools, [])

    case provider do
      :anthropic ->
        Nex.Agent.LLM.Anthropic.chat(messages,
          model: model,
          api_key: api_key,
          tools: tools
        )

      :openai ->
        Nex.Agent.LLM.OpenAI.chat(messages,
          model: model,
          api_key: api_key,
          base_url: base_url,
          tools: tools
        )

      _ ->
        {:error, "Unsupported provider: #{provider}"}
    end
  end

  defp execute_tools(session, messages, tool_calls, opts) do
    ctx = build_tool_ctx(opts)

    results =
      tool_calls
      |> Task.async_stream(
        fn tc ->
          func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

          tool_name =
            Map.get(tc, :name) || Map.get(tc, "name") || Map.get(func, "name") ||
              Map.get(func, :name)

          tool_call_id = Map.get(tc, :id) || Map.get(tc, "id") || generate_tool_call_id()

          args =
            Map.get(tc, :arguments) || Map.get(tc, "arguments") || Map.get(func, "arguments") ||
              Map.get(func, :arguments) || %{}

          args = parse_args(args)

          Logger.info("[Runner] Executing tool: #{tool_name}(#{inspect(args)})")

          result = execute_tool(tool_name, args, ctx)
          truncated = truncate_result(result)

          {tool_call_id, tool_name, truncated}
        end,
        ordered: true,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} ->
          Logger.error("[Runner] Tool task exited: #{inspect(reason)}")
          {generate_tool_call_id(), "unknown", "Error: tool timed out or crashed (#{inspect(reason)})"}
      end)

    {new_messages, session} =
      Enum.reduce(results, {messages, session}, fn {tool_call_id, tool_name, result},
                                                   {msgs, sess} ->
        msgs = ContextBuilder.add_tool_result(msgs, tool_call_id, tool_name, result)
        sess = Session.add_message(sess, "tool", result, tool_call_id: tool_call_id, name: tool_name)

        {msgs, sess}
      end)

    {new_messages, results, session}
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

  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}

  defp execute_tool(tool_name, args, ctx) do
    if Process.whereis(ToolRegistry) do
      case ToolRegistry.execute(tool_name, args, ctx) do
        {:ok, result} when is_binary(result) -> result
        {:ok, %{content: content}} when is_binary(content) -> content
        {:ok, %{error: error}} -> "Error: #{error}"
        {:ok, result} when is_map(result) -> Jason.encode!(result, pretty: true)
        {:ok, result} -> to_string(result)
        {:error, reason} -> "Error: #{reason}"
      end
    else
      execute_tool_fallback(tool_name, args, ctx)
    end
  end

  # Fallback for skill tools (skill_xxx pattern)
  defp execute_tool_fallback(name, args, _ctx) do
    skill_name = String.replace_prefix(name, "skill_", "")

    case Skills.execute(skill_name, args["input"] || args[:input] || "", invoked_by: :model) do
      {:ok, result} when is_binary(result) -> result
      {:ok, %{result: result}} -> to_string(result)
      {:ok, result} -> inspect(result)
      {:error, reason} -> "Error executing skill #{skill_name}: #{inspect(reason)}"
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
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
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
    model = Keyword.get(opts, :model)
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    tools = Keyword.get(opts, :tools, [])

    llm_chat =
      case provider do
        :anthropic -> &Nex.Agent.LLM.Anthropic.chat/2
        :openai -> &Nex.Agent.LLM.OpenAI.chat/2
        :openrouter -> &Nex.Agent.LLM.OpenRouter.chat/2
        :ollama -> &Nex.Agent.LLM.Ollama.chat/2
        _ -> nil
      end

    if is_nil(llm_chat) do
      {:error, "Unsupported provider for consolidation: #{provider}"}
    else
      tool_choice = Keyword.get(opts, :tool_choice)

      call_opts =
        [model: model, api_key: api_key, base_url: base_url, tools: tools] ++
          if tool_choice, do: [tool_choice: tool_choice], else: []

      case llm_chat.(messages, call_opts) do
        {:ok, response} ->
          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if tool_calls && length(tool_calls) > 0 do
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

        error ->
          error
      end
    end
  end
end
