defmodule Nex.Agent.LLM.OpenAI do
  @behaviour Nex.Agent.LLM.Behaviour

  def chat(messages, options) do
    model = Keyword.get(options, :model, "gpt-4o")
    api_key = Keyword.fetch!(options, :api_key)
    base_url = Keyword.get(options, :base_url, "https://api.openai.com/v1")
    max_tokens = Keyword.get(options, :max_tokens, 4096)
    temperature = Keyword.get(options, :temperature, 1.0)
    http_client = Keyword.get(options, :http_client, &Req.post/2)
    tools = Keyword.get(options, :tools, []) |> transform_tools()
    tool_choice = Keyword.get(options, :tool_choice)

    base_url = String.trim_trailing(base_url, "/")

    body = %{
      model: model,
      messages: messages,
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
             {"content-type", "application/json"}
           ],
           receive_timeout: 180_000,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: response}} ->
        case response["choices"] do
          [choice | _] ->
            message = choice["message"] || %{}

            {:ok,
             %{
               content: message["content"],
               reasoning_content: message["reasoning_content"],
               tool_calls: message["tool_calls"] || [],
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
    {:error, "Streaming not implemented for OpenAI"}
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
end
