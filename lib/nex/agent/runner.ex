defmodule Nex.Agent.Runner do
  require Logger

  alias Nex.Agent.{
    Bus,
    Session,
    ContextBuilder,
    Skills,
    Memory
  }

  @default_max_iterations 10
  @memory_window 50
  @max_tool_result_length 2000

  @doc """
  Run agent loop with session and prompt.
  """
  def run(session, prompt, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")

    Logger.info("[Runner] Starting provider=#{provider} model=#{model} channel=#{channel}")

    session = maybe_consolidate_memory(session, provider, model, api_key, base_url)

    history = Session.get_history(session, @memory_window)

    messages =
      ContextBuilder.build_messages(
        history,
        prompt,
        channel,
        chat_id
      )

    session = Session.add_message(session, "user", prompt)

    Logger.info("[Runner] LLM request: history=#{length(history)} messages=#{length(messages)}")

    run_loop(session, messages, 0, max_iterations, opts)
  end

  defp session_history(session) do
    Session.get_history(session, @memory_window)
  end

  defp maybe_consolidate_memory(session, provider, model, api_key, base_url) do
    messages = session.messages
    unconsolidated = length(messages) - session.last_consolidated

    if unconsolidated >= @memory_window do
      Logger.info("[Runner] Triggering memory consolidation: #{unconsolidated} messages")

      case Memory.consolidate(session, provider, model,
             api_key: api_key,
             base_url: base_url,
             memory_window: @memory_window
           ) do
        {:ok, updated_session} ->
          updated_session

        {:error, reason} ->
          Logger.warning("[Runner] Memory consolidation failed: #{inspect(reason)}")
          session
      end
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
      case call_llm(messages, opts) do
        {:ok, response} ->
          content = response.content
          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if tool_calls && tool_calls != [] do
            Logger.info("[Runner] LLM requests #{length(tool_calls)} tool call(s)")

            tool_call_dicts =
              Enum.map(tool_calls, fn tc ->
                %{
                  "id" => Map.get(tc, :id) || Map.get(tc, "id"),
                  "type" => "function",
                  "function" => %{
                    "name" => Map.get(tc, :name) || Map.get(tc, "name"),
                    "arguments" =>
                      Jason.encode!(Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{})
                  }
                }
              end)

            maybe_send_progress(on_progress, content, tool_call_dicts)

            messages = ContextBuilder.add_assistant_message(messages, content, tool_call_dicts)

            session =
              Session.add_message(session, "assistant", content, tool_calls: tool_call_dicts)

            {new_messages, results} = execute_tools(session, messages, tool_calls, opts)

            maybe_publish_tool_results(results, opts)

            run_loop(session, new_messages, iteration + 1, max_iterations, opts)
          else
            Logger.info("[Runner] LLM finished: #{String.slice(content || "", 0, 100)}")
            session = Session.add_message(session, "assistant", content || "")
            {:ok, content || "", session}
          end

        {:error, reason} ->
          Logger.error("[Runner] LLM call failed: #{inspect(reason)}")
          {:error, reason, session}
      end
    end
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
        if String.length(args) > 60, do: String.slice(args, 0, 57) <> "...", else: args

      "#{name}(#{args_preview})"
    end)
  end

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

  defp truncate_result(result) when is_binary(result) and byte_size(result) > @max_tool_result_length do
    String.slice(result, 0, @max_tool_result_length) <> "\n... (truncated)"
  end

  defp truncate_result(result) when is_binary(result), do: result
  defp truncate_result(result), do: inspect(result)

  defp call_llm(messages, opts) do
    tools =
      case Keyword.get(opts, :tools_filter) do
        :subagent -> base_tools()
        _ -> all_tools()
      end

    opts =
      opts
      |> Keyword.put(:tools, tools)

    if opts[:llm_client] do
      opts[:llm_client].(messages, opts)
    else
      call_llm_real(messages, opts)
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

  defp base_tools do
    [
      %{
        "name" => "read",
        "description" => "Read a file from the filesystem",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to file"}
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "write",
        "description" => "Write content to a file",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to file"},
            "content" => %{"type" => "string", "description" => "Content to write"}
          },
          "required" => ["path", "content"]
        }
      },
      %{
        "name" => "bash",
        "description" => "Execute a shell command",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "Command to execute"}
          },
          "required" => ["command"]
        }
      }
    ]
  end

  defp evolution_tools do
    [
      %{
        "name" => "skill_create",
        "description" => "Create a new reusable skill. Use this when you notice a repeated pattern that should be automated.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Skill name (snake_case)"},
            "description" => %{"type" => "string", "description" => "What this skill does"},
            "content" => %{"type" => "string", "description" => "Skill content (markdown instructions or script)"}
          },
          "required" => ["name", "description", "content"]
        }
      },
      %{
        "name" => "soul_update",
        "description" => "Update your SOUL.md personality/behavior file. Use sparingly to record important learned preferences or behavioral adjustments.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "New full content for SOUL.md"}
          },
          "required" => ["content"]
        }
      },
      %{
        "name" => "spawn_task",
        "description" => "Spawn a background subagent to handle a task independently. The result will be reported back when complete.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "task" => %{"type" => "string", "description" => "Description of the task to perform"},
            "label" => %{"type" => "string", "description" => "Short label for the task"}
          },
          "required" => ["task"]
        }
      },
      %{
        "name" => "message",
        "description" => "Send a message to the user immediately without waiting for the full response.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "Message content to send"}
          },
          "required" => ["content"]
        }
      }
    ]
  end

  defp all_tools do
    skills = Skills.for_llm()

    skill_tools =
      Enum.map(skills, fn skill ->
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

    base_tools() ++ evolution_tools() ++ skill_tools
  end

  defp execute_tools(session, messages, tool_calls, opts) do
    results =
      Enum.map(tool_calls, fn tc ->
        tool_name = Map.get(tc, :name) || Map.get(tc, "name")
        tool_call_id = Map.get(tc, :id) || Map.get(tc, "id")
        args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}

        args =
          if is_binary(args) do
            case Jason.decode(args) do
              {:ok, map} -> map
              _ -> %{}
            end
          else
            args
          end

        Logger.info("[Runner] Executing tool: #{tool_name}(#{inspect(args)})")

        result = execute_tool(tool_name, args, opts)
        truncated = truncate_result(result)

        {tool_call_id, tool_name, truncated}
      end)

    new_messages =
      Enum.reduce(results, messages, fn {tool_call_id, tool_name, result}, acc ->
        ContextBuilder.add_tool_result(acc, tool_call_id, tool_name, result)
      end)

    {new_messages, results}
  end

  defp execute_tool("read", args, _opts) do
    path = args["path"] || args[:path]

    if path do
      case File.read(path) do
        {:ok, content} -> content
        {:error, reason} -> "Error reading file: #{inspect(reason)}"
      end
    else
      "Error: path is required"
    end
  end

  defp execute_tool("write", args, _opts) do
    path = args["path"] || args[:path]
    content = args["content"] || args[:content]

    if path && content do
      case File.write(path, content) do
        :ok -> "File written successfully"
        {:error, reason} -> "Error writing file: #{inspect(reason)}"
      end
    else
      "Error: path and content are required"
    end
  end

  defp execute_tool("bash", args, _opts) do
    command = args["command"] || args[:command]

    if command do
      {output, exit_code} = System.cmd("sh", ["-c", command])

      if exit_code == 0 do
        output
      else
        "Error: command exited with code #{exit_code}\n#{output}"
      end
    else
      "Error: command is required"
    end
  end

  defp execute_tool("skill_create", args, _opts) do
    name = args["name"] || args[:name]
    description = args["description"] || args[:description]
    content = args["content"] || args[:content]

    if name && description && content do
      case Skills.create(%{
             name: name,
             description: description,
             type: :markdown,
             content: content
           }) do
        :ok -> "Skill '#{name}' created successfully."
        {:ok, _} -> "Skill '#{name}' created successfully."
        {:error, reason} -> "Error creating skill: #{inspect(reason)}"
      end
    else
      "Error: name, description, and content are required"
    end
  end

  defp execute_tool("soul_update", args, _opts) do
    content = args["content"] || args[:content]

    if content do
      soul_path = Path.join([System.get_env("HOME", "."), ".nex", "agent", "workspace", "SOUL.md"])
      dir = Path.dirname(soul_path)
      File.mkdir_p!(dir)

      case File.write(soul_path, content) do
        :ok -> "SOUL.md updated successfully."
        {:error, reason} -> "Error updating SOUL.md: #{inspect(reason)}"
      end
    else
      "Error: content is required"
    end
  end

  defp execute_tool("spawn_task", args, opts) do
    task_desc = args["task"] || args[:task]
    label = args["label"] || args[:label]

    if task_desc do
      spawn_opts = [
        label: label,
        session_key: Keyword.get(opts, :session_key),
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id)
      ]

      if Process.whereis(Nex.Agent.Subagent) do
        case Nex.Agent.Subagent.spawn_task(task_desc, spawn_opts) do
          {:ok, task_id} -> "Background task spawned: #{task_id} (#{label || "unlabeled"})"
          {:error, reason} -> "Error spawning task: #{inspect(reason)}"
        end
      else
        "Error: Subagent service is not running"
      end
    else
      "Error: task description is required"
    end
  end

  defp execute_tool("message", args, opts) do
    content = args["content"] || args[:content]
    channel = Keyword.get(opts, :channel)
    chat_id = Keyword.get(opts, :chat_id)

    if content && channel && chat_id do
      outbound_topic =
        case channel do
          "telegram" -> :telegram_outbound
          "feishu" -> :feishu_outbound
          "http" -> :http_outbound
          _ -> :outbound
        end

      if Process.whereis(Bus) do
        Bus.publish(outbound_topic, %{
          chat_id: chat_id,
          content: content,
          metadata: %{"channel" => channel, "chat_id" => chat_id}
        })
      end

      "Message sent."
    else
      "Error: content is required"
    end
  end

  defp execute_tool(name, args, _opts) do
    skill_name =
      if String.starts_with?(name, "skill_") do
        String.replace_prefix(name, "skill_", "")
      else
        name
      end

    case Skills.execute(skill_name, args["input"] || args[:input] || "") do
      {:ok, result} -> result
      {:error, reason} -> "Error executing skill #{skill_name}: #{inspect(reason)}"
    end
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

    case provider do
      :anthropic ->
        case Nex.Agent.LLM.Anthropic.chat(messages,
               model: model,
               api_key: api_key,
               tools: tools
             ) do
          {:ok, response} ->
            tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

            if tool_calls && length(tool_calls) > 0 do
              tc = List.first(tool_calls)
              args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}

              args =
                if is_binary(args) do
                  case Jason.decode(args) do
                    {:ok, map} -> map
                    _ -> %{}
                  end
                else
                  args
                end

              {:ok, args}
            else
              {:error, "No tool call in response"}
            end

          error ->
            error
        end

      _ ->
        {:error, "Unsupported provider for consolidation: #{provider}"}
    end
  end
end
