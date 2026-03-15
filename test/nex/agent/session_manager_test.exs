defmodule Nex.Agent.SessionManagerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Session, SessionManager}

  setup do
    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    key = "session-manager-test:#{System.unique_integer([:positive])}"
    path = session_path_for(key)

    on_exit(fn ->
      SessionManager.invalidate(key)
      File.rm_rf!(Path.dirname(path))
    end)

    {:ok, key: key, path: path}
  end

  test "finish_consolidation clears consolidation flags instead of reviving them", %{key: key} do
    session =
      Session.new(key)
      |> Map.put(:metadata, %{"runtime_evolution" => %{"turns_since_memory_write" => 9}})

    :ok = Session.save(session)

    assert {:ok, marked_session, _} = SessionManager.start_consolidation(key, 0)
    assert marked_session.metadata["consolidation_in_progress"] == true
    assert is_binary(marked_session.metadata["consolidation_started_at"])

    SessionManager.finish_consolidation(marked_session)
    Process.sleep(50)

    reloaded = Session.load(key)

    refute Map.has_key?(reloaded.metadata, "consolidation_in_progress")
    refute Map.has_key?(reloaded.metadata, "consolidation_started_at")
    assert get_in(reloaded.metadata, ["runtime_evolution", "turns_since_memory_write"]) == 9
  end

  test "stale consolidation flags are recovered before the next consolidation attempt", %{
    key: key
  } do
    stale_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    session =
      Session.new(key)
      |> Map.put(:metadata, %{
        "consolidation_in_progress" => true,
        "consolidation_started_at" => stale_timestamp
      })

    :ok = Session.save(session)

    assert {:ok, marked_session, 0} = SessionManager.start_consolidation(key, 0)
    assert marked_session.metadata["consolidation_in_progress"] == true
    assert marked_session.metadata["consolidation_started_at"] != stale_timestamp
  end

  defp session_path_for(key) do
    safe_filename =
      key
      |> String.replace(":", "_")
      |> String.replace(~r/[^\w-]/, "_")

    Path.join([
      System.get_env("HOME", "~"),
      ".nex/agent/workspace/sessions",
      safe_filename,
      "messages.jsonl"
    ])
  end
end
