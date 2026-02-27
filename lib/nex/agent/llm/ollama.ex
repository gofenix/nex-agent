defmodule Nex.Agent.LLM.Ollama do
  @behaviour Nex.Agent.LLM.Behaviour

  def chat(messages, options) do
    model = Keyword.get(options, :model, "llama3.1")
    base_url = Keyword.get(options, :base_url, "http://localhost:11434/v1")
    http_client = Keyword.get(options, :http_client, &Req.post/2)

    body = %{
      model: model,
      messages: transform_messages(messages),
      stream: false
    }

    result =
      http_client.("#{base_url}/chat/completions",
        json: body,
        headers: [{"content-type", "application/json"}]
      )

    case result do
      {:ok, %{status: 200, body: response}} ->
        {:ok,
         %{
           content: hd(response["choices"])["message"]["content"],
           model: response["model"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, error: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream(_messages, _options, _callback) do
    {:error, "Streaming not implemented for Ollama"}
  end

  def tools, do: []

  # Public for testing
  def transform_messages(messages) do
    messages
    |> Enum.filter(fn m -> m["role"] != "system" end)
  end
end
