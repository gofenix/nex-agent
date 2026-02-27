defmodule Nex.Agent.Runner do
  alias Nex.Agent.{
    Session,
    Entry,
    Tool.Read,
    Tool.Write,
    Tool.Edit,
    Tool.Bash
  }

  @default_max_iterations 10

  @doc """
  Run an agent session with the given prompt.
  
  Options:
    - :max_iterations - Maximum number of iterations (default: 10)
    - :provider - LLM provider (:anthropic, :openai, :ollama)
    - :model - Model name
    - :api_key - API key for the provider
    - :base_url - Custom base URL for the provider
    - :cwd - Current working directory
    - :llm_client - For testing: a function that mocks LLM responses
  """
  def run(session, prompt, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.get(opts, :api_key)
    base_url = Keyword.get(opts, :base_url)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    llm_client = Keyword.get(opts, :llm_client)

    system_prompt = Nex.Agent.SystemPrompt.build(cwd: cwd)

    messages = [
      %{"role" => "system", "content" => system_prompt}
      | Session.current_messages(session)
    ]

    user_message = %{"role" => "user", "content" => prompt}
    session = add_message(session, user_message)
    messages = messages ++ [user_message]

    run_loop(session, messages, 0, max_iterations,
      provider: provider,
      model: model,
      api_key: api_key,
      base_url: base_url,
      cwd: cwd,
      llm_client: llm_client
    )
  end

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    if iteration >= max_iterations do
      {:error, :max_iterations_exceeded, session}
    else
      case call_llm(messages, opts) do
        {:ok, response} ->
          content = response.content
          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if tool_calls && tool_calls != [] do
            session =
              add_message(session, %{
                "role" => "assistant",
                "content" => content,
                "tool_calls" => tool_calls
              })

            messages =
              messages ++
                [%{"role" => "assistant", "content" => content, "tool_calls" => tool_calls}]

            {new_messages, _results} = execute_tools(session, messages, tool_calls, opts)
            run_loop(session, new_messages, iteration + 1, max_iterations, opts)
          else
            session = add_message(session, %{"role" => "assistant", "content" => content})
            {:ok, content, session}
          end

        {:error, reason} ->
          {:error, reason, session}
      end
    end
  end

  defp call_llm(messages, opts) do
    # Check if a test client is provided
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

    provider_opts =
      [
        model: model,
        api_key: api_key,
        base_url: base_url
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case provider do
      :anthropic ->
        Nex.Agent.LLM.Anthropic.chat(messages, provider_opts)

      :openai ->
        Nex.Agent.LLM.OpenAI.chat(messages, provider_opts)

      :ollama ->
        Nex.Agent.LLM.Ollama.chat(messages, provider_opts)

      _ ->
        {:error, "Unknown provider: #{provider}"}
    end
  end

  defp execute_tools(_session, messages, tool_calls, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    results =
      Enum.map(tool_calls, fn tc ->
        tool_name = tc["function"]["name"]
        args = tc["function"]["arguments"]

        result = execute_tool(tool_name, args, cwd: cwd)

        tool_result = %{
          "role" => "tool",
          "tool_call_id" => tc["id"],
          "content" => format_result(result)
        }

        {tc["id"], tool_result}
      end)

    tool_messages = Enum.map(results, fn {_, msg} -> msg end)
    {messages ++ tool_messages, results}
  end

  defp execute_tool("read", args, opts) do
    Read.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("write", args, opts) do
    Write.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("edit", args, opts) do
    Edit.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool("bash", args, opts) do
    Bash.execute(args, %{cwd: opts[:cwd]})
  end

  defp execute_tool(name, _args, _opts) do
    {:error, "Unknown tool: #{name}"}
  end

  defp format_result({:ok, result}) when is_map(result) do
    result |> Map.values() |> Enum.join("\n")
  end

  defp format_result({:error, error}) do
    "Error: #{error}"
  end

  defp add_message(session, message) do
    entry = Entry.new_message(session.current_entry_id, message)
    Session.add_entry(session, entry)
  end
end
