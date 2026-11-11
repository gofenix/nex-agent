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

    :ok = Session.save(session, workspace: workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, key: key}
  end

  test "reports pending state when the session still has unreviewed messages", %{
    workspace: workspace,
    key: key
  } do
    assert {:ok, status} =
             MemoryStatus.execute(%{}, %{workspace: workspace, session_key: key})

    assert status["status"] == "pending"
    assert status["reason"] == "unreviewed_messages"
    assert status["session"]["exists"] == true
    assert status["session"]["total_messages"] == 63
    assert status["session"]["last_reviewed_message_count"] == 10
    assert status["session"]["unreviewed_messages"] == 53
    assert status["memory_files"]["memory_has_user_content"] == true
    assert status["memory_files"]["memory_bytes"] > 0
    assert status["refresh"]["job_status"] == "idle"
    assert status["refresh"]["queued_jobs_for_session"] == 0
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
    assert status["reason"] == "unreviewed_messages"
  end

  test "legacy consolidation flags do not change the refresh status", %{
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

    :ok = Session.save(stuck_session, workspace: workspace)

    assert {:ok, status} =
             MemoryStatus.execute(%{}, %{workspace: workspace, session_key: key})

    assert status["status"] == "pending"
    assert status["reason"] == "unreviewed_messages"
    assert status["session"]["unreviewed_messages"] == 10
    refute Map.has_key?(status["session"], "consolidation_in_progress")
    refute Map.has_key?(status, "runtime_evolution")
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
end
