defmodule Nex.Agent.LLM.Anthropic do
  @behaviour Nex.Agent.LLM.Behaviour

  @base_url "https://api.anthropic.com/v1"

  def chat(messages, options) do
    model = Keyword.get(options, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.fetch!(options, :api_key)
    max_tokens = Keyword.get(options, :max_tokens, 4096)
    temperature = Keyword.get(options, :temperature, 1.0)
    http_client = Keyword.get(options, :http_client, &Req.post/2)
    tools = Keyword.get(options, :tools, [])
    tool_choice = Keyword.get(options, :tool_choice)

    system_content = extract_system(messages)

    system_block =
      if system_content do
        [%{type: "text", text: system_content, cache_control: %{type: "ephemeral"}}]
      else
        nil
      end

    body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: temperature,
      messages: transform_messages(messages)
    }

    body = if system_block, do: Map.put(body, :system, system_block), else: body

    body =
      if tools != [] do
        body = Map.put(body, :tools, transform_tools(tools))

        if tool_choice do
          Map.put(body, :tool_choice, tool_choice)
        else
          body
        end
      else
        body
      end

    result =
      http_client.("#{@base_url}/messages",
        json: body,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"anthropic-beta", "prompt-caching-2024-07-31"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 180_000,
        connect_options: [timeout: 30_000]
      )

    case result do
      {:ok, %{status: 200, body: response}} ->
        content = response["content"] |> Enum.find(fn c -> c["type"] == "text" end)
        tool_calls = response["content"] |> Enum.filter(fn c -> c["type"] == "tool_use" end)
        stop_reason = response["stop_reason"]

        {:ok,
         %{
           content: content && content["text"],
           tool_calls:
             if tool_calls != [] do
               Enum.map(tool_calls, fn tc ->
                 %{
                   id: tc["id"],
                   name: tc["name"],
                   arguments: tc["input"]
                 }
               end)
             else
               nil
             end,
           finish_reason: stop_reason,
           model: response["model"],
           usage: response["usage"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream(messages, options, callback) do
    model = Keyword.get(options, :model, "claude-sonnet-4-20250514")
    api_key = Keyword.fetch!(options, :api_key)
    http_client = Keyword.get(options, :http_client, &Req.post/2)

    body = %{
      model: model,
      max_tokens: 4096,
      temperature: 1.0,
      messages: transform_messages(messages),
      system: extract_system(messages),
      stream: true
    }

    req =
      Req.new(
        url: "#{@base_url}/messages",
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ]
      )

    result = http_client.(req, json: body)

    case result do
      {:ok, %{status: 200, body: stream}} ->
        Stream.each(stream, fn chunk ->
          callback.(chunk)
        end)
        |> Stream.run()

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def tools, do: []

  # Public for testing
  def transform_messages(messages) do
    messages
    |> Enum.filter(fn m -> m["role"] != "system" end)
    |> Enum.map(fn m ->
      case m["role"] do
        "assistant" ->
          tool_calls = m["tool_calls"]
          content = m["content"]
          has_tool_calls = is_list(tool_calls) and tool_calls != []

          cond do
            has_tool_calls and content != nil and content != "" ->
              tool_use_blocks =
                Enum.map(tool_calls, fn tc ->
                  args = tc["function"]["arguments"]
                  input = safe_decode_args(args)

                  %{
                    type: "tool_use",
                    id: tc["id"] || generate_id(),
                    name: tc["function"]["name"],
                    input: input
                  }
                end)

              %{
                role: "assistant",
                content: [%{type: "text", text: content} | tool_use_blocks]
              }

            has_tool_calls ->
              %{
                role: "assistant",
                content:
                  Enum.map(tool_calls, fn tc ->
                    args = tc["function"]["arguments"]
                    input = safe_decode_args(args)

                    %{
                      type: "tool_use",
                      id: tc["id"] || generate_id(),
                      name: tc["function"]["name"],
                      input: input
                    }
                  end)
              }

            true ->
              %{role: "assistant", content: content}
          end

        "tool" ->
          %{
            role: "user",
            content: [
              %{
                type: "tool_result",
                tool_use_id: m["tool_call_id"] || generate_id(),
                content: m["content"] || ""
              }
            ]
          }

        _ ->
          %{role: m["role"], content: m["content"]}
      end
    end)
    |> merge_consecutive_user_messages()
  end

  # Anthropic requires alternating user/assistant messages.
  # Merge consecutive user messages (e.g. runtime context + tool results).
  defp merge_consecutive_user_messages(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case {acc, msg} do
          {nil, _} ->
            {:cont, msg}

          {%{role: "user"}, %{role: "user"}} ->
            {:cont, merge_user(acc, msg)}

          {prev, _} ->
            {:cont, prev, msg}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp merge_user(%{role: "user", content: c1}, %{role: "user", content: c2}) do
    %{role: "user", content: normalize_content(c1) ++ normalize_content(c2)}
  end

  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content) when is_binary(content), do: [%{type: "text", text: content}]
  defp normalize_content(nil), do: [%{type: "text", text: ""}]

  # Public for testing
  def extract_system(messages) do
    messages
    |> Enum.find(fn m -> m["role"] == "system" end)
    |> case do
      nil -> nil
      m -> m["content"]
    end
  end

  defp transform_tools(tools) do
    Enum.map(tools, fn tool ->
      input_schema = Map.get(tool, "input_schema") || %{}

      %{
        name: tool["name"],
        description: tool["description"],
        input_schema: input_schema
      }
    end)
  end

  defp safe_decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      _ -> %{"_raw" => args}
    end
  end

  defp safe_decode_args(args), do: args

  defp generate_id do
    "toolu_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
