defmodule Nex.Agent.LLM.OpenRouter do
  @behaviour Nex.Agent.LLM.Behaviour

  def chat(messages, options) do
    model = Keyword.get(options, :model, "anthropic/claude-3.5-sonnet")
    api_key = Keyword.fetch!(options, :api_key)
    base_url = Keyword.get(options, :base_url, "https://openrouter.ai/api/v1")
    max_tokens = Keyword.get(options, :max_tokens, 4096)
    temperature = Keyword.get(options, :temperature, 0.1)
    http_client = Keyword.get(options, :http_client, &Req.post/2)

    base_url = String.trim_trailing(base_url, "/")

    body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    }

    case http_client.("#{base_url}/chat/completions",
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"},
             {"http-referer", "https://nex.dev"},
             {"x-title", "Nex Agent"}
           ]
         ) do
      {:ok, %{status: 200, body: response}} ->
        choice = hd(response["choices"])
        message = choice["message"] || %{}

        {:ok,
         %{
           content: message["content"],
           tool_calls: message["tool_calls"] || [],
           model: response["model"],
           usage: response["usage"]
         }}

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
end
