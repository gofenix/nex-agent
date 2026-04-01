defmodule Nex.Agent.LLM.ReqLLMTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.LLM.ReqLLM, as: AgentReqLLM
  alias ReqLLM.Message

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
    assert model_spec == %{id: "qwen2.5:latest", provider: :openai, base_url: "http://localhost:11434/v1"}
    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == "ollama"
    assert opts[:base_url] == "http://localhost:11434/v1"
  end
end
