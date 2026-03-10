defmodule Nex.Agent.LLM.ReqLLMTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.LLM.ReqLLM, as: Adapter
  alias ReqLLM.Message
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  test "chat transforms messages, tools, and normalized response shape" do
    generate_text_fun = fn model_spec, messages, opts ->
      assert model_spec == "openai:gpt-4o"
      assert Enum.map(messages, & &1.role) == [:system, :user, :assistant, :tool]

      assert %Message{tool_calls: [%ToolCall{function: %{name: "list_dir"}}]} =
               Enum.at(messages, 2)

      assert %Message{tool_call_id: "call_123", name: "list_dir"} = Enum.at(messages, 3)

      assert Enum.all?(opts[:tools], &match?(%Tool{}, &1))
      assert opts[:tool_choice] == %{"type" => "function", "function" => %{"name" => "list_dir"}}

      {:ok,
       %{
         content: "listed",
         thinking: "checking",
         tool_calls: [%{id: "call_123", name: "list_dir", arguments: %{"path" => "."}}],
         finish_reason: :tool_calls,
         model: "gpt-4o",
         usage: %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end

    assert {:ok, response} =
             Adapter.chat(
               [
                 %{"role" => "system", "content" => "You are helpful"},
                 %{"role" => "user", "content" => "list files"},
                 %{
                   "role" => "assistant",
                   "content" => "",
                   "tool_calls" => [
                     %{
                       "id" => "call_123",
                       "type" => "function",
                       "function" => %{"name" => "list_dir", "arguments" => ~s({"path":"."})}
                     }
                   ]
                 },
                 %{
                   "role" => "tool",
                   "tool_call_id" => "call_123",
                   "name" => "list_dir",
                   "content" => "[]"
                 }
               ],
               provider: :openai,
               model: "gpt-4o",
               api_key: "sk-test",
               tools: [
                 %{
                   "name" => "list_dir",
                   "description" => "List files",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"path" => %{"type" => "string"}}
                   }
                 }
               ],
               tool_choice: %{"type" => "function", "function" => %{"name" => "list_dir"}},
               req_llm_generate_text_fun: generate_text_fun
             )

    assert response.content == "listed"
    assert response.reasoning_content == "checking"
    assert response.finish_reason == "tool_calls"
    assert response.model == "gpt-4o"
    assert response.usage == %{"input_tokens" => 10, "output_tokens" => 5}

    assert response.tool_calls == [
             %{
               "id" => "call_123",
               "type" => "function",
               "function" => %{"name" => "list_dir", "arguments" => ~s({"path":"."})}
             }
           ]
  end

  test "chat maps openrouter and ollama through unified adapter" do
    parent = self()

    generate_text_fun = fn model_spec, _messages, opts ->
      send(parent, {:req_call, model_spec, opts})
      {:ok, %{content: "ok", finish_reason: :stop, tool_calls: [], model: "stub"}}
    end

    assert {:ok, _} =
             Adapter.chat(
               [%{"role" => "user", "content" => "hi"}],
               provider: :openrouter,
               model: "anthropic/claude-3.5-sonnet",
               api_key: "or-key",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert_received {:req_call, %{provider: :openrouter, id: "anthropic/claude-3.5-sonnet"}, opts}
    assert opts[:base_url] == "https://openrouter.ai/api/v1"
    assert opts[:provider_options] == [app_referer: "https://nex.dev", app_title: "Nex Agent"]

    assert {:ok, _} =
             Adapter.chat(
               [%{"role" => "user", "content" => "hi"}],
               provider: :ollama,
               model: "llama3.1",
               base_url: "http://localhost:11434",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert_received {:req_call,
                     %{provider: :openai, id: "llama3.1", base_url: "http://localhost:11434/v1"},
                     opts}

    assert opts[:base_url] == "http://localhost:11434/v1"
  end

  test "stream emits normalized events and final metadata" do
    stream_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         stream: [
           %{type: :content, text: "Hel"},
           %{type: :thinking, text: "Analyzing"},
           %{type: :tool_call, id: "call_1", name: "list_dir", arguments: %{"path" => "."}},
           %{type: :content, text: "lo"}
         ],
         finish_reason: :tool_calls,
         usage: %{"output_tokens" => 12},
         model: "gpt-4o"
       }}
    end

    callback = fn event -> send(self(), {:stream_event, event}) end

    assert :ok =
             Adapter.stream(
               [%{"role" => "user", "content" => "hi"}],
               [
                 provider: :openai,
                 model: "gpt-4o",
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_received {:stream_event, {:delta, "Hel"}}
    assert_received {:stream_event, {:thinking, "Analyzing"}}

    assert_received {:stream_event,
                     {:tool_calls,
                      [
                        %{
                          "id" => "call_1",
                          "type" => "function",
                          "function" => %{"name" => "list_dir", "arguments" => ~s({"path":"."})}
                        }
                      ]}}

    assert_received {:stream_event,
                     {:done,
                      %{
                        finish_reason: "tool_calls",
                        usage: %{"output_tokens" => 12},
                        model: "gpt-4o"
                      }}}
  end

  test "chat preserves multimodal user content parts" do
    generate_text_fun = fn _model_spec, messages, _opts ->
      assert %Message{content: content_parts} = List.first(messages)
      assert Enum.any?(content_parts, &match?(%ReqLLM.Message.ContentPart{type: :image_url}, &1))
      assert Enum.any?(content_parts, &match?(%ReqLLM.Message.ContentPart{type: :text}, &1))

      {:ok, %{content: "ok", finish_reason: :stop, tool_calls: [], model: "stub"}}
    end

    assert {:ok, response} =
             Adapter.chat(
               [
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "image",
                       "source" => %{
                         "type" => "url",
                         "url" => "https://example.com/image.jpg",
                         "media_type" => "image/jpeg"
                       }
                     },
                     %{"type" => "text", "text" => "describe this"}
                   ]
                 }
               ],
               provider: :openai,
               model: "gpt-4o",
               api_key: "sk-test",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert response.content == "ok"
  end

  test "chat falls back to real req_llm function when no hook is provided" do
    assert {:error, _reason} =
             Adapter.chat(
               [%{"role" => "user", "content" => "hello"}],
               provider: :openai,
               model: "gpt-4o"
             )
  end

  test "chat strips think tags from final content and preserves reasoning" do
    generate_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         content: "<think>\ninternal reasoning\n</think>\n\nOK",
         finish_reason: :stop,
         tool_calls: [],
         model: "MiniMax-M2.1",
         usage: %{}
       }}
    end

    assert {:ok, response} =
             Adapter.chat(
               [%{"role" => "user", "content" => "Reply with exactly OK."}],
               provider: :openai,
               model: "MiniMax-M2.1",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert response.content == "OK"
    assert response.reasoning_content == "internal reasoning"
  end
end
