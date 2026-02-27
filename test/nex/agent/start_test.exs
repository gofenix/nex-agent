defmodule Nex.Agent.StartTest do
  use ExUnit.Case, async: true

  describe "Nex.Agent struct" do
    test "creates struct with fields" do
      agent = %Nex.Agent{
        session: nil,
        provider: :anthropic,
        model: "claude-3",
        api_key: "test-key",
        base_url: nil
      }

      assert agent.provider == :anthropic
      assert agent.model == "claude-3"
      assert agent.api_key == "test-key"
    end

    test "struct has correct type" do
      defstruct_test = %Nex.Agent{}
      assert is_struct(defstruct_test, Nex.Agent)
    end
  end

  describe "Nex.Agent.start/1" do
    test "returns error when no API key" do
      # Clear any existing API key for this test
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("OLLAMA_HOST")

      result = Nex.Agent.start(provider: :anthropic, api_key: nil)
      assert {:error, _} = result
    end
  end

  describe "Nex.Agent functions" do
    test "session_id returns session id" do
      # Just test that the function exists and is callable
      assert function_exported?(Nex.Agent, :session_id, 1)
      assert function_exported?(Nex.Agent, :fork, 1)
      assert function_exported?(Nex.Agent, :start, 1)
      assert function_exported?(Nex.Agent, :prompt, 2)
    end
  end
end
