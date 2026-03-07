defmodule Nex.Agent.LLM.OpenRouter do
  @behaviour Nex.Agent.LLM.Behaviour

  def chat(messages, options) do
    model = Keyword.get(options, :model, "anthropic/claude-3.5-sonnet")
    api_key = Keyword.fetch!(options, :api_key)
    base_url = Keyword.get(options, :base_url, "https://openrouter.ai/api/v1")
    max_tokens = Keyword.get(options, :max_tokens, 4096)
    temperature = Keyword.get(options, :temperature, 0.1)
    http_client = Keyword.get(options, :http_client, &Req.post/2)
    tools = Keyword.get(options, :tools, []) |> transform_tools()
    tool_choice = Keyword.get(options, :tool_choice)

    base_url = String.trim_trailing(base_url, "/")

    body = %{
      model: model,
      messages: transform_messages(messages),
      temperature: temperature,
      max_tokens: max_tokens
    }

    body =
      if tools != [] do
        body
        |> Map.put(:tools, tools)
        |> then(fn b -> if tool_choice, do: Map.put(b, :tool_choice, tool_choice), else: b end)
      else
        body
      end

    case http_client.("#{base_url}/chat/completions",
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"},
             {"http-referer", "https://nex.dev"},
             {"x-title", "Nex Agent"}
           ],
           receive_timeout: 180_000,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: response}} ->
        case response["choices"] do
          [choice | _] ->
            message = choice["message"] || %{}

            # Parse tool calls from OpenAI format back to our internal format
            tool_calls =
              (message["tool_calls"] || [])
              |> Enum.map(fn tc ->
                %{
                  "id" => tc["id"],
                  "type" => tc["type"],
                  "function" => %{
                    "name" => tc["function"]["name"],
                    "arguments" => tc["function"]["arguments"]
                  }
                }
              end)

            {:ok,
             %{
               content: message["content"],
               tool_calls: tool_calls,
               finish_reason: choice["finish_reason"],
               model: response["model"],
               usage: response["usage"]
             }}

          _ ->
            {:error, "Empty response from LLM: no choices returned"}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream(_messages, _options, _callback) do
    {:error, "Streaming not implemented for OpenRouter"}
  end

  def tools, do: []

  defp transform_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      func = tool["function"] || %{}
      name = tool["name"] || func["name"]
      description = tool["description"] || func["description"]
      parameters = tool["input_schema"] || func["parameters"] || %{type: "object", properties: %{}}

      %{
        type: "function",
        function: %{
          name: name,
          description: description,
          parameters: parameters
        }
      }
    end)
  end

  defp transform_tools(_), do: []

  defp generate_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  defp transform_messages(messages) do
    Enum.map(messages, fn m ->
      cond do
        m["role"] == "assistant" && m["tool_calls"] && m["tool_calls"] != [] ->
          %{
            "role" => "assistant",
            "content" => m["content"],
            "tool_calls" => m["tool_calls"]
          }

        m["role"] == "tool" ->
          %{
            "role" => "tool",
            "tool_call_id" => m["tool_call_id"] || generate_id(),
            "name" => m["name"] || "tool",
            "content" => m["content"]
          }

        true ->
          %{
            "role" => m["role"],
            "content" => m["content"]
          }
      end
    end)
  end
end
