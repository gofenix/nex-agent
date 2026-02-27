defmodule Nex.Agent.LLM.OllamaTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.LLM.Ollama

  describe "chat/2" do
    test "uses default model and base_url with mock" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end
      result = Ollama.chat([%{"role" => "user", "content" => "hello"}], http_client: mock_http)
      assert {:error, :econnrefused} = result
    end

    test "allows custom model and base_url with mock" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Ollama.chat(
          [%{"role" => "user", "content" => "hello"}],
          model: "custom-model",
          base_url: "http://localhost:8080/v1",
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end
  end

  describe "stream/3" do
    test "returns streaming not implemented error" do
      result = Ollama.stream([], [], fn _ -> nil end)
      assert result == {:error, "Streaming not implemented for Ollama"}
    end
  end

  describe "tools/0" do
    test "returns empty list" do
      assert Ollama.tools() == []
    end
  end

  describe "chat with mocked HTTP - success cases" do
    test "returns content on 200 response" do
      mock_http = fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [%{"message" => %{"content" => "Hello from Ollama"}}],
             "model" => "llama3.1"
           }
         }}
      end

      result =
        Ollama.chat(
          [%{"role" => "user", "content" => "hello"}],
          http_client: mock_http
        )

      assert {:ok, %{content: "Hello from Ollama", model: "llama3.1"}} = result
    end

    test "returns error on non-200 status" do
      mock_http = fn _url, _opts ->
        {:ok, %{status: 500, body: %{"error" => "Server error"}}}
      end

      result =
        Ollama.chat(
          [%{"role" => "user", "content" => "hello"}],
          http_client: mock_http
        )

      assert {:error, %{status: 500, error: %{"error" => "Server error"}}} = result
    end

    test "returns error on HTTP error" do
      mock_http = fn _url, _opts ->
        {:error, :timeout}
      end

      result =
        Ollama.chat(
          [%{"role" => "user", "content" => "hello"}],
          http_client: mock_http
        )

      assert {:error, :timeout} = result
    end
  end

  describe "transform_messages/1" do
    test "filters out system messages" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

      result = Ollama.transform_messages(messages)
      assert length(result) == 1
      assert hd(result)["role"] == "user"
    end

    test "handles empty messages" do
      result = Ollama.transform_messages([])
      assert result == []
    end

    test "handles assistant messages (passes through)" do
      messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there"}
      ]

      result = Ollama.transform_messages(messages)
      assert length(result) == 2
    end

    test "handles tool messages" do
      messages = [
        %{"role" => "tool", "content" => "Result", "tool_call_id" => "call_123"}
      ]

      result = Ollama.transform_messages(messages)
      assert length(result) == 1
    end

    test "handles multiple system messages" do
      messages = [
        %{"role" => "system", "content" => "First"},
        %{"role" => "system", "content" => "Second"},
        %{"role" => "user", "content" => "Hello"}
      ]

      result = Ollama.transform_messages(messages)
      # Both system messages filtered, only user remains
      assert length(result) == 1
    end

    test "handles only system messages" do
      messages = [%{"role" => "system", "content" => "You are helpful"}]
      result = Ollama.transform_messages(messages)
      # System messages filtered
      assert result == []
    end
  end

  describe "custom options" do
    test "accepts custom base_url without trailing slash" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Ollama.chat([%{"role" => "user", "content" => "test"}],
          base_url: "http://localhost:8080",
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end

    test "accepts custom base_url with trailing slash" do
      mock_http = fn _url, _opts -> {:error, :econnrefused} end

      result =
        Ollama.chat([%{"role" => "user", "content" => "test"}],
          base_url: "http://localhost:8080/",
          http_client: mock_http
        )

      assert {:error, :econnrefused} = result
    end
  end
end
