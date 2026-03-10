defmodule Nex.Agent.RunnerReqLLMTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Runner

  test "call_llm_for_consolidation uses req_llm adapter response shape" do
    generate_text_fun = fn _model_spec, _messages, opts ->
      assert opts[:tool_choice] == %{
               "type" => "function",
               "function" => %{"name" => "save_memory"}
             }

      {:ok,
       %{
         content: "",
         finish_reason: :tool_calls,
         tool_calls: [
           %{
             id: "call_save_memory",
             name: "save_memory",
             arguments: %{"content" => "remember this"}
           }
         ]
       }}
    end

    assert {:ok, %{"content" => "remember this"}} =
             Runner.call_llm_for_consolidation(
               [%{"role" => "user", "content" => "remember this"}],
               provider: :openai,
               model: "gpt-4o",
               tool_choice: %{"type" => "function", "function" => %{"name" => "save_memory"}},
               tools: [
                 %{
                   "name" => "save_memory",
                   "description" => "Save memory",
                   "input_schema" => %{
                     "type" => "object",
                     "properties" => %{"content" => %{"type" => "string"}},
                     "required" => ["content"]
                   }
                 }
               ],
               req_llm_generate_text_fun: generate_text_fun
             )
  end
end
