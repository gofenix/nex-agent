defmodule Nex.Agent.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.LLM.Anthropic

  describe "Nex.Agent.LLM.Anthropic" do
    test "module loads" do
      assert Code.ensure_loaded?(Nex.Agent.LLM.Anthropic)
    end

    test "chat with mocked HTTP returns error on connection failure" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end

    test "stream with mocked HTTP returns error on connection failure" do
      mock_http = fn _req, _opts -> {:error, :econnrefused} end
      result = Anthropic.stream([], [api_key: "test", http_client: mock_http], fn _ -> nil end)
      assert {:error, :econnrefused} = result
    end

    test "tools returns list" do
      assert is_list(Anthropic.tools())
    end

    test "accepts custom model" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          model: "claude-3-opus",
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end

    test "accepts custom max_tokens and temperature" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          max_tokens: 100,
          temperature: 0.5,
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end

    test "raises when api_key is missing" do
      assert_raise KeyError, fn ->
        Anthropic.chat([], [])
      end
    end
  end

  describe "chat with mocked HTTP - success cases" do
    test "returns content on 200 response" do
      mock_http = fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"text" => "Hello response"}],
             "model" => "claude-3",
             "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
           }
         }}
      end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          http_client: mock_http
        )

      assert {:ok, %{content: "Hello response", model: "claude-3"}} = result
    end

    test "returns error on non-200 status" do
      mock_http = fn _url, _opts ->
        {:ok, %{status: 429, body: %{"error" => "Rate limited"}}}
      end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          http_client: mock_http
        )

      assert {:error, %{status: 429, error: %{"error" => "Rate limited"}}} = result
    end

    test "returns error on HTTP error" do
      mock_http = fn _url, _opts -> {:error, :timeout} end

      result =
        Anthropic.chat([%{"role" => "user", "content" => "hello"}],
          api_key: "test",
          http_client: mock_http
        )

      assert {:error, :timeout} = result
    end
  end

  describe "stream with mocked HTTP" do
    test "streams on 200 response" do
      mock_http = fn _req, _opts ->
        {:ok,
         %{
           status: 200,
           body: [%{"type" => "content_block_delta", "delta" => %{"text" => "Hello"}}]
         }}
      end

      callback = fn _chunk -> :ok end

      result =
        Anthropic.stream(
          [%{"role" => "user", "content" => "hello"}],
          [api_key: "test", http_client: mock_http],
          callback
        )

      assert result == :ok
    end

    test "returns error on non-200 status" do
      mock_http = fn _req, _opts ->
        {:ok, %{status: 500, body: %{"error" => "Server error"}}}
      end

      result =
        Anthropic.stream(
          [%{"role" => "user", "content" => "hello"}],
          [api_key: "test", http_client: mock_http],
          fn _ -> nil end
        )

      assert {:error, %{status: 500, error: %{"error" => "Server error"}}} = result
    end
  end

  describe "transform_messages/1" do
    test "filters out system messages" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

      result = Anthropic.transform_messages(messages)
      # System message should be filtered
      assert length(result) == 1
    end

    test "handles assistant message without tool_calls" do
      messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there"}
      ]

      result = Anthropic.transform_messages(messages)
      assert length(result) == 2
    end

    test "handles assistant message with tool_calls" do
      messages = [
        %{"role" => "user", "content" => "Read the file"},
        %{"role" => "assistant", "content" => "I'll read it", "tool_calls" => [
          %{"id" => "call_123", "function" => %{"name" => "read", "arguments" => "{\"path\": \"test.ex\"}"}}
        ]}
      ]

      result = Anthropic.transform_messages(messages)
      # Should not crash and produce output
      assert is_list(result)
      assert length(result) == 2
    end

    test "handles tool message" do
      messages = [
        %{"role" => "user", "content" => "Read the file"},
        %{"role" => "tool", "content" => "File content here", "tool_call_id" => "call_123"}
      ]

      result = Anthropic.transform_messages(messages)
      assert is_list(result)
      assert length(result) == 2
    end

    test "handles mixed message types" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi"},
        %{"role" => "tool", "content" => "Result", "tool_call_id" => "call_1"},
        %{"role" => "user", "content" => "Thanks"}
      ]

      result = Anthropic.transform_messages(messages)
      # filtered system
      assert length(result) == 4
    end

    test "handles empty messages" do
      result = Anthropic.transform_messages([])
      assert result == []
    end

    test "handles assistant with empty tool_calls" do
      messages = [
        %{"role" => "assistant", "content" => "Hello", "tool_calls" => []}
      ]

      result = Anthropic.transform_messages(messages)
      assert length(result) == 1
    end
  end

  describe "extract_system/1" do
    test "extracts system message content" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

      result = Anthropic.extract_system(messages)
      assert result == "You are helpful"
    end

    test "returns nil when no system message" do
      messages = [
        %{"role" => "user", "content" => "Hello"}
      ]

      result = Anthropic.extract_system(messages)
      assert result == nil
    end

    test "returns nil for empty messages" do
      result = Anthropic.extract_system([])
      assert result == nil
    end
  end
end
