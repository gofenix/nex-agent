defmodule Nex.Agent.RunnerTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Runner
  alias Nex.Agent.Session

  describe "Nex.Agent.Runner" do
    test "module loads" do
      assert Code.ensure_loaded?(Nex.Agent.Runner)
    end

    test "run/3 exists with correct arity" do
      assert is_function(&Runner.run/3)
    end

    test "run with unknown provider returns error tuple" do
      {:ok, session} = Session.create("test-project")
      result = Runner.run(session, "test", provider: :Unknown)
      assert {:error, _message, _session} = result
    end

    test "run with max_iterations=0 returns max_iterations_exceeded" do
      {:ok, session} = Session.create("test-project")
      result = Runner.run(session, "test", max_iterations: 0, api_key: "test")
      assert {:error, :max_iterations_exceeded, _} = result
    end

    test "run preserves session through error" do
      {:ok, session} = Session.create("test-project")
      original_id = session.id
      result = Runner.run(session, "test", provider: :Unknown)
      assert {:error, _, returned_session} = result
      assert returned_session.id == original_id
    end
  end

  describe "Runner with mocked LLM" do
    test "run with simple response (no tools)" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:ok, %{content: "Hello, this is a test response"}}
      end

      result =
        Runner.run(session, "test prompt",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 1
        )

      assert {:ok, "Hello, this is a test response", _updated_session} = result
    end

    test "run handles LLM error response" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:error, "API rate limit exceeded"}
      end

      result =
        Runner.run(session, "test",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 1
        )

      assert {:error, "API rate limit exceeded", updated_session} = result
      assert updated_session.id == session.id
    end

    test "run reaches max_iterations with tool calls" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:ok,
         %{
           content: "Need to do more",
           tool_calls: [
             %{
               "id" => "call_1",
               "function" => %{
                 "name" => "read",
                 "arguments" => %{"path" => "/tmp/test.txt"}
               }
             }
           ]
         }}
      end

      result =
        Runner.run(session, "infinite loop",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 3
        )

      assert {:error, :max_iterations_exceeded, _} = result
    end

    test "run with empty tool_calls" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:ok,
         %{
           content: "No tools needed",
           tool_calls: []
         }}
      end

      result =
        Runner.run(session, "simple question",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 1
        )

      assert {:ok, "No tools needed", _} = result
    end

    test "run with nil tool_calls" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:ok, %{content: "Simple response"}}
      end

      result =
        Runner.run(session, "simple question",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 1
        )

      assert {:ok, "Simple response", _} = result
    end

    test "run with tool call that succeeds and returns" do
      {:ok, session} = Session.create("test-project")

      Process.put(:call_count, 0)

      mock_client = fn _messages, _opts ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        if count == 0 do
          {:ok,
           %{
             content: "I'll read the file",
             tool_calls: [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "read",
                   "arguments" => %{"path" => "/etc/hosts"}
                 }
               }
             ]
           }}
        else
          {:ok, %{content: "Found the file content"}}
        end
      end

      result =
        Runner.run(session, "read /etc/hosts",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 3
        )

      assert {:ok, "Found the file content", _} = result
    end

    test "run with tool call that returns error" do
      {:ok, session} = Session.create("test-project")

      mock_client = fn _messages, _opts ->
        {:ok,
         %{
           content: "I'll try to read",
           tool_calls: [
             %{
               "id" => "call_1",
               "function" => %{
                 "name" => "read",
                 "arguments" => %{"path" => "/nonexistent/file.txt"}
               }
             }
           ]
         }}
      end

      result =
        Runner.run(session, "read nonexistent",
          provider: :anthropic,
          api_key: "test",
          llm_client: mock_client,
          max_iterations: 2
        )

      # Should continue with error from tool and then return
      assert is_tuple(result)
    end

    test "run with unknown tool name reaches max iterations" do
      {:ok, session} = Session.create("test-project")
      
      # Mock always returns unknown tool call - will hit max iterations
      mock_client = fn _messages, _opts ->
        {:ok, %{
          content: "I'll use a custom tool",
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "nonexistent_tool",
                "arguments" => %{}
              }
            }
          ]
        }}
      end
      
      result = Runner.run(session, "use custom tool",
        provider: :anthropic,
        api_key: "test",
        llm_client: mock_client,
        max_iterations: 2
      )
      
      # With unknown tool, it keeps retrying until max_iterations
      assert {:error, :max_iterations_exceeded, _} = result
    end
  end
end
