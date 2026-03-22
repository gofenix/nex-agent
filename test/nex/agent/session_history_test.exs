defmodule Nex.Agent.SessionHistoryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Session

  test "get_history prepends the matching assistant tool call when the window starts at tool result" do
    session =
      %{
        Session.new("history-tool-boundary")
        | messages: build_tool_boundary_messages("read_19")
      }

    history = Session.get_history(session, 50)

    assert hd(history)["role"] == "assistant"
    assert get_in(hd(history), ["tool_calls"]) |> hd() |> Map.get("id") == "read_19"
    assert Enum.at(history, 1)["role"] == "tool"
    assert Enum.at(history, 1)["tool_call_id"] == "read_19"
  end

  test "get_history drops leading orphaned tool results when no matching assistant tool call exists" do
    session =
      %{
        Session.new("history-orphan-tool")
        | messages: build_orphan_tool_boundary_messages("read_19")
      }

    history = Session.get_history(session, 50)

    refute history == []
    refute hd(history)["role"] == "tool"
    refute Enum.any?(Enum.take(history, 1), &Map.has_key?(&1, "tool_call_id"))
  end

  defp build_tool_boundary_messages(tool_call_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    [
      %{"role" => "user", "content" => "开始", "timestamp" => now},
      %{
        "role" => "assistant",
        "content" => "继续看错误处理部分。",
        "timestamp" => now,
        "tool_calls" => [
          %{
            "id" => tool_call_id,
            "type" => "function",
            "function" => %{
              "name" => "read",
              "arguments" => Jason.encode!(%{"path" => "lib/nex/agent/runner.ex"})
            }
          }
        ]
      },
      %{
        "role" => "tool",
        "content" => "defmodule Nex.Agent.Runner do\n",
        "timestamp" => now,
        "tool_call_id" => tool_call_id,
        "name" => "read"
      }
      | Enum.map(1..49, fn idx ->
          %{
            "role" => "assistant",
            "content" => "后续分析 #{idx}",
            "timestamp" => now
          }
        end)
    ]
  end

  defp build_orphan_tool_boundary_messages(tool_call_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    [
      %{"role" => "user", "content" => "开始", "timestamp" => now},
      %{
        "role" => "assistant",
        "content" => "这条 assistant 没有 tool_calls。",
        "timestamp" => now
      },
      %{
        "role" => "tool",
        "content" => "orphan tool result",
        "timestamp" => now,
        "tool_call_id" => tool_call_id,
        "name" => "read"
      }
      | Enum.map(1..49, fn idx ->
          %{
            "role" => "assistant",
            "content" => "后续分析 #{idx}",
            "timestamp" => now
          }
        end)
    ]
  end
end
