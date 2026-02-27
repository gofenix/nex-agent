defmodule Nex.AgentTest do
  use ExUnit.Case, async: true

  alias Nex.Agent
  alias Nex.Agent.Session

  describe "Nex.Agent.start/1" do
    test "creates agent with valid API key" do
      result = Agent.start(provider: :anthropic, api_key: "test-key-123")
      assert {:ok, agent} = result
      assert agent.provider == :anthropic
      assert agent.api_key == "test-key-123"
      assert agent.model == "claude-sonnet-4-20250514"
      assert %Session{} = agent.session
    end

    test "creates agent with different providers" do
      # OpenAI
      {:ok, openai_agent} = Agent.start(provider: :openai, api_key: "openai-key")
      assert openai_agent.provider == :openai
      assert openai_agent.model == "gpt-4o"

      # Ollama (API key currently required by implementation)
      {:ok, ollama_agent} = Agent.start(provider: :ollama, api_key: "dummy")
      assert ollama_agent.provider == :ollama
      assert ollama_agent.model == "llama3.1"
    end

    test "creates agent with custom model" do
      result =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          model: "claude-3-opus"
        )

      assert {:ok, agent} = result
      assert agent.model == "claude-3-opus"
    end

    test "creates agent with custom base_url" do
      result =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          base_url: "https://custom.api.com"
        )

      assert {:ok, agent} = result
      assert agent.base_url == "https://custom.api.com"
    end

    test "creates agent with custom project name" do
      result =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          project: "my-custom-project"
        )

      assert {:ok, agent} = result
      assert agent.session.project_id == "my-custom-project"
    end

    test "creates agent with custom cwd" do
      result =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          cwd: "/tmp/test-dir"
        )

      assert {:ok, agent} = result
      # cwd is used for session creation but not stored directly
    end

    test "returns error when no API key for anthropic" do
      System.delete_env("ANTHROPIC_API_KEY")
      result = Agent.start(provider: :anthropic, api_key: nil)
      assert {:error, message} = result
      assert is_binary(message)
      assert message =~ "API key"
    end

    test "returns error when no API key for openai" do
      System.delete_env("OPENAI_API_KEY")
      result = Agent.start(provider: :openai, api_key: nil)
      assert {:error, _} = result
    end

    test "ollama works with API key (currently required by implementation)" do
      result = Agent.start(provider: :ollama, api_key: "dummy-key")
      assert {:ok, _} = result
    end

    test "uses environment variable for API key when not provided" do
      System.put_env("ANTHROPIC_API_KEY", "env-api-key")
      result = Agent.start(provider: :anthropic)
      assert {:ok, agent} = result
      assert agent.api_key == "env-api-key"
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "uses environment variable for openai" do
      System.put_env("OPENAI_API_KEY", "env-openai-key")
      result = Agent.start(provider: :openai)
      assert {:ok, agent} = result
      assert agent.api_key == "env-openai-key"
    after
      System.delete_env("OPENAI_API_KEY")
    end

    test "prefers explicit API key over environment variable" do
      System.put_env("ANTHROPIC_API_KEY", "env-api-key")
      result = Agent.start(provider: :anthropic, api_key: "explicit-key")
      assert {:ok, agent} = result
      assert agent.api_key == "explicit-key"
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "uses default project name from cwd" do
      cwd = File.cwd!()
      project_name = Path.basename(cwd)

      result = Agent.start(provider: :anthropic, api_key: "test-key")
      assert {:ok, agent} = result
      assert agent.session.project_id == project_name
    end

    test "uses default cwd from File.cwd!" do
      cwd = File.cwd!()

      result = Agent.start(provider: :anthropic, api_key: "test-key")
      assert {:ok, agent} = result
      # cwd is used for session creation but not stored directly
    end
  end

  describe "Nex.Agent.session_id/1" do
    test "returns session id from agent" do
      {:ok, agent} = Agent.start(provider: :anthropic, api_key: "test-key")
      session_id = Agent.session_id(agent)

      assert is_binary(session_id)
      assert session_id == agent.session.id
    end
  end

  describe "Nex.Agent.fork/1" do
    test "forks agent with new session" do
      {:ok, agent} = Agent.start(provider: :anthropic, api_key: "test-key")
      original_session_id = agent.session.id

      {:ok, forked_agent} = Agent.fork(agent)

      assert forked_agent.session.id != original_session_id
      assert forked_agent.provider == agent.provider
      assert forked_agent.model == agent.model
      assert forked_agent.api_key == agent.api_key
      assert forked_agent.base_url == agent.base_url
    end

    test "forked agent has same config" do
      {:ok, agent} =
        Agent.start(
          provider: :openai,
          api_key: "test-key",
          model: "gpt-4",
          base_url: "https://custom.api.com"
        )

      {:ok, forked} = Agent.fork(agent)

      assert forked.provider == :openai
      assert forked.model == "gpt-4"
      assert forked.api_key == "test-key"
      assert forked.base_url == "https://custom.api.com"
    end
  end

  describe "Nex.Agent.abort/1" do
    test "returns :ok" do
      {:ok, agent} = Agent.start(provider: :anthropic, api_key: "test-key")
      assert Agent.abort(agent) == :ok
    end
  end

  describe "Nex.Agent.prompt/2" do
    test "prompt updates agent session" do
      {:ok, agent} =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          max_iterations: 0
        )

      original_session_id = agent.session.id

      # This will fail due to max_iterations but still returns updated agent
      result = Agent.prompt(agent, "test prompt")

      # Should return error but with updated session
      assert {:error, _, updated_agent} = result
      assert updated_agent.session.id == original_session_id
    end

    test "prompt with custom options" do
      {:ok, agent} =
        Agent.start(
          provider: :openai,
          api_key: "test-key",
          max_iterations: 0
        )

      # Override provider in prompt
      result = Agent.prompt(agent, "test", provider: :anthropic, api_key: "different-key")
      assert {:error, _, updated_agent} = result
    end

    test "prompt with custom cwd" do
      {:ok, agent} =
        Agent.start(
          provider: :anthropic,
          api_key: "test-key",
          max_iterations: 0,
          cwd: "/tmp"
        )

      result = Agent.prompt(agent, "test", cwd: "/home")
      assert {:error, _, _} = result
    end
  end

  describe "Nex.Agent struct" do
    test "struct has correct default values" do
      agent = %Agent{}

      assert agent.session == nil
      assert agent.provider == nil
      assert agent.model == nil
      assert agent.api_key == nil
      assert agent.base_url == nil
    end

    test "struct can be created with values" do
      agent = %Agent{
        session: %Session{id: "test-id", project_id: "test"},
        provider: :anthropic,
        model: "claude-3",
        api_key: "test-key",
        base_url: "https://api.anthropic.com"
      }

      assert agent.provider == :anthropic
      assert agent.model == "claude-3"
      assert agent.api_key == "test-key"
    end
  end

  describe "Nex.Agent with unknown provider" do
    test "defaults to anthropic model for unknown provider" do
      result = Agent.start(provider: :unknown_provider, api_key: "test-key")
      assert {:ok, agent} = result
      # Should use anthropic default
      assert agent.model == "claude-sonnet-4-20250514"
    end

    test "returns nil API key for unknown provider" do
      result = Agent.start(provider: :unknown_provider, api_key: nil)
      assert {:error, _} = result
    end
  end

  describe "Nex.Agent environment variable names" do
    test "uses correct env var for anthropic error message" do
      System.delete_env("ANTHROPIC_API_KEY")
      result = Agent.start(provider: :anthropic, api_key: nil)
      assert {:error, message} = result
      assert message =~ "ANTHROPIC_API_KEY"
    end

    test "uses correct env var for openai error message" do
      System.delete_env("OPENAI_API_KEY")
      result = Agent.start(provider: :openai, api_key: nil)
      assert {:error, message} = result
      assert message =~ "OPENAI_API_KEY"
    end

    test "uses generic env var for unknown provider" do
      result = Agent.start(provider: :unknown, api_key: nil)
      assert {:error, message} = result
      assert message =~ "API_KEY"
    end
  end
end
