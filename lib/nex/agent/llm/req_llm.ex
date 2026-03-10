defmodule Nex.Agent.LLM.ReqLLM do
  @behaviour Nex.Agent.LLM.Behaviour

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @openrouter_referer "https://nex.dev"
  @openrouter_title "Nex Agent"
  @chat_timeout 180_000

  def chat(messages, options) do
    model_spec = resolve_model(options)
    req_messages = messages |> sanitize_messages() |> transform_messages()
    req_options = build_req_llm_options(options)

    generate_text_fun =
      Keyword.get(options, :req_llm_generate_text_fun) || (&ReqLLM.generate_text/3)

    try do
      case generate_text_fun.(model_spec, req_messages, req_options) do
        {:ok, response} -> {:ok, parse_response(response)}
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    rescue
      error -> {:error, normalize_error(error)}
    end
  end

  def stream(messages, options, callback) do
    model_spec = resolve_model(options)
    req_messages = messages |> sanitize_messages() |> transform_messages()
    req_options = build_req_llm_options(options)
    stream_text_fun = Keyword.get(options, :req_llm_stream_text_fun) || (&ReqLLM.stream_text/3)

    try do
      case stream_text_fun.(model_spec, req_messages, req_options) do
        {:ok, %StreamResponse{} = response} ->
          state =
            Enum.reduce(response.stream, %{tool_calls: []}, fn chunk, acc ->
              handle_stream_chunk(chunk, callback, acc)
            end)

          emit_stream_done(callback, Enum.reverse(state.tool_calls), %{
            finish_reason: normalize_finish_reason(StreamResponse.finish_reason(response)),
            usage: StreamResponse.usage(response),
            model: extract_stream_model(response)
          })

          :ok

        {:ok, response} when is_map(response) ->
          state =
            Enum.reduce(
              Map.get(response, :stream) || Map.get(response, "stream") || [],
              %{tool_calls: []},
              fn chunk, acc ->
                handle_stream_chunk(chunk, callback, acc)
              end
            )

          emit_stream_done(callback, Enum.reverse(state.tool_calls), %{
            finish_reason:
              normalize_finish_reason(
                Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
              ),
            usage: Map.get(response, :usage) || Map.get(response, "usage"),
            model: extract_stream_model(response)
          })

          :ok

        {:error, reason} ->
          error = normalize_error(reason)
          callback.({:error, error})
          {:error, error}
      end
    rescue
      error ->
        normalized = normalize_error(error)
        callback.({:error, normalized})
        {:error, normalized}
    end
  end

  def tools, do: []

  defp sanitize_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> Map.take(["role", "content", "tool_calls", "tool_call_id", "name", "reasoning_content"])
      |> drop_nil_values()
    end)
  end

  defp transform_messages(messages) do
    Enum.map(messages, fn message ->
      case message["role"] do
        "system" ->
          build_message(:system, message["content"])

        "assistant" ->
          content = message["content"]
          tool_calls = to_req_llm_tool_calls(message["tool_calls"] || [])

          opts =
            []
            |> maybe_put_keyword(:tool_calls, tool_calls != [], tool_calls)
            |> maybe_put_keyword(
              :metadata,
              present?(message["reasoning_content"]),
              %{reasoning_content: message["reasoning_content"]}
            )

          build_message(:assistant, content, opts)

        "tool" ->
          Context.tool_result(
            message["tool_call_id"] || generate_tool_call_id(),
            message["name"] || "tool",
            to_req_llm_content(message["content"])
          )

        _ ->
          build_message(:user, message["content"])
      end
    end)
  end

  defp build_req_llm_options(options) do
    provider = Keyword.get(options, :provider, :anthropic)
    resolved_provider = resolve_provider(options)
    base_url = effective_base_url(provider, options[:base_url])

    []
    |> maybe_put_keyword(:api_key, present?(options[:api_key]), options[:api_key])
    |> maybe_put_keyword(:base_url, present?(base_url), base_url)
    |> maybe_put_keyword(:temperature, is_number(options[:temperature]), options[:temperature])
    |> maybe_put_keyword(:max_tokens, is_integer(options[:max_tokens]), options[:max_tokens])
    |> maybe_put_keyword(:tools, true, transform_tools(options[:tools] || []))
    |> maybe_put_keyword(
      :tool_choice,
      not is_nil(options[:tool_choice]),
      normalize_tool_choice(options[:tool_choice])
    )
    |> maybe_put_keyword(:receive_timeout, true, @chat_timeout)
    |> maybe_put_keyword(:provider_options, true, provider_options(resolved_provider))
  end

  defp transform_tools(tools) do
    Enum.map(tools, fn tool ->
      Tool.new!(
        name: tool["name"],
        description: tool["description"] || "",
        parameter_schema: tool["input_schema"] || %{},
        callback: fn _args -> {:ok, "Tool execution is handled by NexAgent"} end
      )
    end)
  end

  defp resolve_provider(options) do
    case Keyword.get(options, :provider, :anthropic) do
      :ollama -> :openai
      provider -> provider
    end
  end

  defp resolve_model(options) do
    provider = Keyword.get(options, :provider, :anthropic)
    resolved_provider = resolve_provider(options)
    model = Keyword.get(options, :model) || default_model(provider)
    base_url = effective_base_url(provider, Keyword.get(options, :base_url))

    if present?(base_url) or provider in [:openrouter, :ollama] do
      %{id: model, provider: resolved_provider, base_url: base_url}
    else
      "#{resolved_provider}:#{model}"
    end
  end

  defp effective_base_url(:openrouter, nil), do: "https://openrouter.ai/api/v1"
  defp effective_base_url(:ollama, nil), do: "http://localhost:11434/v1"
  defp effective_base_url(:ollama, base_url), do: normalize_ollama_base_url(base_url)
  defp effective_base_url(_provider, base_url), do: base_url

  defp provider_options(:openrouter),
    do: [app_referer: @openrouter_referer, app_title: @openrouter_title]

  defp provider_options(_), do: []

  defp parse_response(%Response{} = response) do
    classified = Response.classify(response)
    reasoning_content = normalized_reasoning_content(classified.thinking, classified.text)
    content = sanitize_final_content(classified.text)

    %{
      content: content,
      reasoning_content: reasoning_content,
      tool_calls: normalize_tool_calls(classified.tool_calls),
      finish_reason: normalize_finish_reason(classified.finish_reason),
      model: extract_model(response),
      usage: Response.usage(response)
    }
  end

  defp parse_response(response) when is_map(response) do
    raw_content =
      Map.get(response, :content) || Map.get(response, "content") || Map.get(response, :text) ||
        Map.get(response, "text")

    raw_reasoning =
      Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content") ||
        Map.get(response, :thinking) || Map.get(response, "thinking")

    %{
      content: sanitize_final_content(raw_content),
      reasoning_content: normalized_reasoning_content(raw_reasoning, raw_content),
      tool_calls:
        normalize_tool_calls(
          Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
        ),
      finish_reason:
        normalize_finish_reason(
          Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
        ),
      model: extract_model(response),
      usage: Map.get(response, :usage) || Map.get(response, "usage")
    }
  end

  defp emit_stream_done(callback, tool_calls, metadata) do
    if tool_calls != [] do
      callback.({:tool_calls, tool_calls})
    end

    callback.({:done, metadata})
  end

  defp handle_stream_chunk(chunk, callback, state) do
    case normalize_stream_event(chunk) do
      {:delta, text} ->
        callback.({:delta, text})
        state

      {:thinking, text} ->
        callback.({:thinking, text})
        state

      {:tool_call, tool_call} ->
        %{state | tool_calls: [tool_call | state.tool_calls]}

      nil ->
        state
    end
  end

  defp normalize_stream_event(%StreamChunk{type: :content, text: text}) when is_binary(text),
    do: {:delta, text}

  defp normalize_stream_event(%StreamChunk{type: :thinking, text: text}) when is_binary(text),
    do: {:thinking, text}

  defp normalize_stream_event(%StreamChunk{
         type: :tool_call,
         name: name,
         arguments: arguments,
         metadata: metadata
       }) do
    id =
      Map.get(metadata || %{}, :id) || Map.get(metadata || %{}, "id") || generate_tool_call_id()

    {:tool_call, normalize_tool_call(%{id: id, name: name, arguments: arguments || %{}})}
  end

  defp normalize_stream_event(%StreamChunk{}), do: nil

  defp normalize_stream_event(%{type: :content, text: text}) when is_binary(text),
    do: {:delta, text}

  defp normalize_stream_event(%{type: :thinking, text: text}) when is_binary(text),
    do: {:thinking, text}

  defp normalize_stream_event(%{type: :tool_call, name: name, arguments: arguments} = chunk) do
    id = Map.get(chunk, :id) || Map.get(chunk, "id") || generate_tool_call_id()
    {:tool_call, normalize_tool_call(%{id: id, name: name, arguments: arguments || %{}})}
  end

  defp normalize_stream_event(_), do: nil

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &normalize_tool_call/1)
  end

  defp normalize_tool_calls(_), do: []

  defp to_req_llm_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      normalized = normalize_tool_call(tool_call)

      ToolCall.new(
        normalized["id"],
        normalized["function"]["name"],
        normalized["function"]["arguments"]
      )
    end)
  end

  defp to_req_llm_tool_calls(_), do: []

  defp normalize_tool_call(%ToolCall{} = tool_call) do
    %{
      "id" => tool_call.id,
      "type" => "function",
      "function" => %{
        "name" => tool_call.function.name,
        "arguments" => tool_call.function.arguments
      }
    }
  end

  defp normalize_tool_call(%{function: %{name: name, arguments: arguments}} = tool_call) do
    %{
      "id" => Map.get(tool_call, :id) || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(
         %{"function" => %{"name" => name, "arguments" => arguments}} = tool_call
       ) do
    %{
      "id" => Map.get(tool_call, "id") || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(%{name: name, arguments: arguments} = tool_call) do
    %{
      "id" => Map.get(tool_call, :id) || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(%{"name" => name, "arguments" => arguments} = tool_call) do
    %{
      "id" => Map.get(tool_call, "id") || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(other) do
    %{
      "id" => generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => "unknown",
        "arguments" => encode_arguments(other)
      }
    }
  end

  defp normalize_tool_choice(nil), do: nil
  defp normalize_tool_choice(choice) when is_map(choice), do: choice
  defp normalize_tool_choice(choice) when is_binary(choice), do: choice
  defp normalize_tool_choice(choice) when is_atom(choice), do: Atom.to_string(choice)
  defp normalize_tool_choice(choice), do: choice

  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(reason) when is_binary(reason), do: reason
  defp normalize_finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_finish_reason(reason), do: to_string(reason)

  defp normalize_error(%{message: _} = error), do: error
  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp extract_model(%Response{model: model}), do: model
  defp extract_model(%{model: model}), do: model
  defp extract_model(%{"model" => model}), do: model
  defp extract_model(_), do: nil

  defp extract_stream_model(%StreamResponse{model: model}) when is_map(model),
    do: Map.get(model, :id) || Map.get(model, "id")

  defp extract_stream_model(%{model: model}) when is_binary(model), do: model
  defp extract_stream_model(%{"model" => model}) when is_binary(model), do: model

  defp extract_stream_model(%{model: model}) when is_map(model),
    do: Map.get(model, :id) || Map.get(model, "id")

  defp extract_stream_model(_), do: nil

  defp maybe_put_keyword(opts, _key, false, _value), do: opts
  defp maybe_put_keyword(opts, _key, _condition, nil), do: opts
  defp maybe_put_keyword(opts, key, _condition, value), do: Keyword.put(opts, key, value)

  defp build_message(role, content, opts \\ [])

  defp build_message(:system, content, _opts) do
    Context.system(to_req_llm_content(content))
  end

  defp build_message(:user, content, _opts) do
    Context.user(to_req_llm_content(content))
  end

  defp build_message(:assistant, content, opts) do
    Context.assistant(to_req_llm_content(content), opts)
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments), do: Jason.encode!(arguments || %{})

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text

  defp to_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      other when is_binary(other) -> other
      _ -> ""
    end)
  end

  defp to_text(other), do: to_string(other)

  defp to_req_llm_content(content) when is_binary(content), do: content
  defp to_req_llm_content(nil), do: ""

  defp to_req_llm_content(content) when is_list(content) do
    Enum.map(content, &to_content_part/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      parts -> parts
    end
  end

  defp to_req_llm_content(other), do: to_text(other)

  defp to_content_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: ContentPart.text(text)

  defp to_content_part(%{type: "text", text: text}) when is_binary(text),
    do: ContentPart.text(text)

  defp to_content_part(%{"type" => "image", "source" => %{"type" => "url", "url" => url}})
       when is_binary(url),
       do: ContentPart.image_url(url)

  defp to_content_part(%{
         type: "image",
         source: %{type: "url", url: url}
       })
       when is_binary(url),
       do: ContentPart.image_url(url)

  defp to_content_part(%ContentPart{} = part), do: part
  defp to_content_part(text) when is_binary(text), do: ContentPart.text(text)
  defp to_content_part(_), do: nil

  defp present?(value) when value in [nil, "", []], do: false
  defp present?(_), do: true

  defp sanitize_final_content(content) when is_binary(content) do
    content
    |> String.replace(~r/<think>.*?<\/think>\s*/s, "")
    |> String.trim()
  end

  defp sanitize_final_content(content), do: content

  defp normalized_reasoning_content(reasoning_content, content)
       when is_binary(reasoning_content) do
    reasoning_content =
      reasoning_content
      |> String.trim()

    if reasoning_content == "" do
      extract_think_block(content)
    else
      reasoning_content
    end
  end

  defp normalized_reasoning_content(_reasoning_content, content), do: extract_think_block(content)

  defp extract_think_block(content) when is_binary(content) do
    case Regex.run(~r/<think>\s*(.*?)\s*<\/think>/s, content, capture: :all_but_first) do
      [think] ->
        think
        |> String.trim()
        |> case do
          "" -> ""
          value -> value
        end

      _ ->
        ""
    end
  end

  defp extract_think_block(_), do: ""

  defp normalize_ollama_base_url(nil), do: "http://localhost:11434/v1"

  defp normalize_ollama_base_url(base_url) do
    if String.ends_with?(base_url, "/v1") do
      base_url
    else
      String.trim_trailing(base_url, "/") <> "/v1"
    end
  end

  defp default_model(:anthropic), do: "claude-sonnet-4-20250514"
  defp default_model(:openai), do: "gpt-4o"
  defp default_model(:openrouter), do: "anthropic/claude-3.5-sonnet"
  defp default_model(:ollama), do: "llama3.1"
  defp default_model(_), do: "gpt-4o"

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
