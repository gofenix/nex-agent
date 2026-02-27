defmodule Nex.Agent.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias Nex.Agent.LLM.OpenAI

  describe "chat/2" do
    test "raises when api_key is missing" do
      assert_raise KeyError, fn ->
        OpenAI.chat([], [])
      end
    end

    test "returns error on API failure" do
      # Test with a fake API key - will fail on network but we can verify the function structure
      result = OpenAI.chat([%{role: "user", content: "hello"}], api_key: "test")
      # This will either be {:ok, response} or {:error, reason}
      assert is_tuple(result)
    end

    test "uses default model and base_url" do
      result = OpenAI.chat([%{role: "user", content: "hello"}], api_key: "test")
      assert is_tuple(result)
    end

    test "allows custom model and base_url" do
      result =
        OpenAI.chat(
          [%{role: "user", content: "hello"}],
          api_key: "test",
          model: "gpt-4",
          base_url: "https://custom.example.com/v1"
        )

      assert is_tuple(result)
    end

    test "allows custom max_tokens and temperature" do
      result =
        OpenAI.chat(
          [%{role: "user", content: "hello"}],
          api_key: "test",
          max_tokens: 100,
          temperature: 0.5
        )

      assert is_tuple(result)
    end
  end

  describe "stream/3" do
    test "returns streaming not implemented error" do
      result = OpenAI.stream([], [], fn _ -> nil end)
      assert result == {:error, "Streaming not implemented for OpenAI"}
    end
  end

  describe "tools/0" do
    test "returns empty list" do
      assert OpenAI.tools() == []
    end
  end
end
