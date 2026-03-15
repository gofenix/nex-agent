defmodule Nex.Agent.MemoryStatusTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Session, Skills}
  alias Nex.Agent.Tool.MemoryStatus

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-memory-status-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))

    File.write!(Path.join(workspace, "memory/MEMORY.md"), """
    # Long-term Memory

    ## Environment Facts

    Deployed in test mode.
    """)

    File.write!(Path.join(workspace, "memory/HISTORY.md"), """
    # Conversation History Log

    [2026-03-15 10:00] User asked about memory consolidation behavior.
    """)

    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    key = "memory-status:#{System.unique_integer([:positive])}"

    session =
      Session.new(key)
      |> Map.put(:last_consolidated, 10)
      |> Map.put(:messages, build_messages(63))
      |> Map.put(:metadata, %{
        "runtime_evolution" => %{"turns_since_memory_write" => 5}
      })

    :ok = Session.save(session)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
      File.rm_rf!(session_dir_for(key))
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "reports ready state when unconsolidated messages exceed the threshold", %{
    workspace: workspace,
    key: key
  } do
    assert {:ok, status} =
             MemoryStatus.execute(%{}, %{workspace: workspace, session_key: key})

    assert status["status"] == "ready"
    assert status["reason"] == "threshold_reached"
    assert status["session"]["unconsolidated_messages"] == 53
    assert status["memory_files"]["memory_has_user_content"] == true
    assert status["memory_files"]["history_has_entries"] == true
    assert status["runtime_evolution"]["turns_since_memory_write"] == 5
    assert status["runtime_evolution"]["next_memory_nudge_due_in_turns"] == 1
  end

  test "derives session key from channel and chat_id when explicit session key is missing", %{
    workspace: workspace,
    key: key
  } do
    [channel, chat_id] = String.split(key, ":", parts: 2)

    assert {:ok, status} =
             MemoryStatus.execute(%{}, %{workspace: workspace, channel: channel, chat_id: chat_id})

    assert status["session_key"] == key
    assert status["session"]["exists"] == true
    assert status["reason"] == "threshold_reached"
  end

  test "reports stale blocked state when consolidation flag is stuck", %{
    workspace: workspace,
    key: key
  } do
    stale_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    stuck_session =
      Session.new(key)
      |> Map.put(:last_consolidated, 10)
      |> Map.put(:messages, build_messages(20))
      |> Map.put(:metadata, %{
        "consolidation_in_progress" => true,
        "consolidation_started_at" => stale_timestamp,
        "runtime_evolution" => %{"turns_since_memory_write" => 0}
      })

    :ok = Session.save(stuck_session)

    assert {:ok, status} =
             MemoryStatus.execute(%{}, %{workspace: workspace, session_key: key})

    assert status["status"] == "blocked"
    assert status["reason"] == "stale_consolidation_flag"
    assert status["session"]["consolidation_in_progress"] == true
    assert status["session"]["consolidation_stale"] == true
  end

  defp build_messages(count) do
    Enum.map(1..count, fn i ->
      %{
        "role" => if(rem(i, 2) == 0, do: "assistant", else: "user"),
        "content" => "message-#{i}",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end)
  end

  defp session_dir_for(key) do
    safe_filename =
      key
      |> String.replace(":", "_")
      |> String.replace(~r/[^\w-]/, "_")

    Path.join([
      System.get_env("HOME", "~"),
      ".nex/agent/workspace/sessions",
      safe_filename
    ])
  end
end
