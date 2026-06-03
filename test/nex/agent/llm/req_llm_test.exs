defmodule Nex.Agent.LLM.ReqLLMTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.LLM.ReqLLM, as: AgentReqLLM
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response

  test "ollama requests use a non-empty placeholder api key" do
    previous_openai_key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "")

    on_exit(fn ->
      if previous_openai_key do
        System.put_env("OPENAI_API_KEY", previous_openai_key)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    parent = self()

    generate_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{content: "ok", finish_reason: :stop, tool_calls: []}}
    end

    assert {:ok, response} =
             AgentReqLLM.chat(
               [%{"role" => "user", "content" => "hello from ollama"}],
               provider: :ollama,
               model: "qwen2.5:latest",
               base_url: "http://localhost:11434",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert response.content == "ok"

    assert_receive {:req_llm_call, model_spec, messages, opts}

    assert model_spec == %{
             id: "qwen2.5:latest",
             provider: :openai,
             base_url: "http://localhost:11434/v1"
           }

    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == "ollama"
    assert opts[:base_url] == "http://localhost:11434/v1"
  end

  test "assistant reasoning details are passed back to ReqLLM messages" do
    parent = self()

    generate_text_fun = fn _model_spec, messages, _opts ->
      send(parent, {:req_llm_messages, messages})
      {:ok, %{content: "ok", finish_reason: :stop, tool_calls: []}}
    end

    assert {:ok, _response} =
             AgentReqLLM.chat(
               [
                 %{"role" => "user", "content" => "search"},
                 %{
                   "role" => "assistant",
                   "content" => "I will search.",
                   "reasoning_content" => "Need a current source.",
                   "reasoning_details" => [
                     %{
                       "text" => "Need a current source.",
                       "signature" => "sig_123",
                       "provider" => "anthropic",
                       "format" => "anthropic-thinking-v1",
                       "index" => 0
                     }
                   ],
                   "tool_calls" => [
                     %{
                       "id" => "toolu_1",
                       "function" => %{
                         "name" => "web_search",
                         "arguments" => ~s({"query":"news"})
                       }
                     }
                   ]
                 },
                 %{
                   "role" => "tool",
                   "tool_call_id" => "toolu_1",
                   "name" => "web_search",
                   "content" => "result"
                 }
               ],
               provider: :anthropic,
               model: "claude-sonnet-4-5",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert_receive {:req_llm_messages, [_user, assistant, _tool]}

    assert %Message{role: :assistant, reasoning_details: [%ReasoningDetails{} = detail]} =
             assistant

    assert detail.text == "Need a current source."
    assert detail.signature == "sig_123"
    assert detail.provider == :anthropic
    assert [%ReqLLM.ToolCall{id: "toolu_1"}] = assistant.tool_calls
  end

  test "responses preserve reasoning details for the next tool turn" do
    reasoning_detail = %ReasoningDetails{
      text: "Need to call a tool.",
      signature: "sig_response",
      provider: :anthropic,
      format: "anthropic-thinking-v1",
      index: 0,
      provider_data: %{"type" => "thinking"}
    }

    response = %Response{
      id: "msg_1",
      model: "claude-sonnet-4-5",
      context: %ReqLLM.Context{messages: []},
      message: %Message{
        role: :assistant,
        content: [
          ContentPart.thinking("Need to call a tool."),
          ContentPart.text("Let me check.")
        ],
        reasoning_details: [reasoning_detail]
      },
      finish_reason: :stop,
      usage: %{}
    }

    generate_text_fun = fn _model_spec, _messages, _opts -> {:ok, response} end

    assert {:ok, parsed} =
             AgentReqLLM.chat(
               [%{"role" => "user", "content" => "check"}],
               provider: :anthropic,
               model: "claude-sonnet-4-5",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert parsed.content == "Let me check."
    assert parsed.reasoning_content == "Need to call a tool."

    assert [
             %{
               "text" => "Need to call a tool.",
               "signature" => "sig_response",
               "provider" => "anthropic"
             }
           ] = parsed.reasoning_details
  end

  test "API request errors redact request bodies and secrets" do
    error =
      ReqLLM.Error.API.Request.exception(
        reason: "Provider response error (400): bad sk-secretsecretsecret",
        status: 400,
        response_body:
          ~s({"error":{"message":"bad AWS_SECRET_ACCESS_KEY=rawsecretvalue sk-secretsecretsecret"}}),
        request_body:
          ~s({"messages":[{"content":"DATABASE_URL=postgresql://user:password@localhost/db AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF"}]})
      )

    generate_text_fun = fn _model_spec, _messages, _opts -> {:error, error} end

    assert {:error, sanitized} =
             AgentReqLLM.chat(
               [%{"role" => "user", "content" => "hello"}],
               provider: :anthropic,
               model: "claude-sonnet-4-5",
               req_llm_generate_text_fun: generate_text_fun
             )

    inspected = inspect(sanitized)
    refute inspected =~ "request_body"
    refute inspected =~ "password"
    refute inspected =~ "AKIA1234567890ABCDEF"
    refute inspected =~ "rawsecretvalue"
    refute inspected =~ "sk-secretsecretsecret"
    assert inspected =~ "[REDACTED]"
  end

  test "nested transport error structs are sanitized without treating them as enumerable maps" do
    error = %Protocol.UndefinedError{
      protocol: Enumerable,
      value: %Req.TransportError{reason: :econnrefused}
    }
    generate_text_fun = fn _model_spec, _messages, _opts -> {:error, error} end

    assert {:error, sanitized} =
             AgentReqLLM.chat(
               [%{"role" => "user", "content" => "hello"}],
               provider: :openai,
               model: "gpt-4o",
               req_llm_generate_text_fun: generate_text_fun
             )

    assert sanitized[:protocol] == Enumerable
    assert sanitized[:value][:reason] == :econnrefused
  end
end
