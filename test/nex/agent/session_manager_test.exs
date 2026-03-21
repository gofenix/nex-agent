defmodule Nex.Agent.SessionManagerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Session, SessionManager}

  setup do
    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-session-manager-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    key = "session-manager-test:#{System.unique_integer([:positive])}"
    path = session_path_for(key, workspace)

    on_exit(fn ->
      SessionManager.invalidate(key, workspace: workspace)
      File.rm_rf!(Path.dirname(path))
      File.rm_rf!(workspace)
    end)

    {:ok, key: key, path: path, workspace: workspace}
  end

  test "finish_consolidation clears consolidation flags instead of reviving them", %{
    key: key,
    workspace: workspace
  } do
    session =
      Session.new(key)
      |> Map.put(:metadata, %{"runtime_evolution" => %{"turns_since_memory_write" => 9}})

    :ok = Session.save(session, workspace: workspace)

    assert {:ok, marked_session, _} =
             SessionManager.start_consolidation(key, 0, workspace: workspace)

    assert marked_session.metadata["consolidation_in_progress"] == true
    assert is_binary(marked_session.metadata["consolidation_started_at"])

    SessionManager.finish_consolidation(marked_session, workspace: workspace)
    Process.sleep(50)

    reloaded = Session.load(key, workspace: workspace)

    refute Map.has_key?(reloaded.metadata, "consolidation_in_progress")
    refute Map.has_key?(reloaded.metadata, "consolidation_started_at")
    assert get_in(reloaded.metadata, ["runtime_evolution", "turns_since_memory_write"]) == 9
  end

  test "stale consolidation flags are recovered before the next consolidation attempt", %{
    key: key,
    workspace: workspace
  } do
    stale_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    session =
      Session.new(key)
      |> Map.put(:metadata, %{
        "consolidation_in_progress" => true,
        "consolidation_started_at" => stale_timestamp
      })

    :ok = Session.save(session, workspace: workspace)

    assert {:ok, marked_session, 0} =
             SessionManager.start_consolidation(key, 0, workspace: workspace)

    assert marked_session.metadata["consolidation_in_progress"] == true
    assert marked_session.metadata["consolidation_started_at"] != stale_timestamp
  end

  test "same session key stays isolated across workspaces" do
    workspace_a =
      Path.join(System.tmp_dir!(), "nex-agent-session-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "nex-agent-session-b-#{System.unique_integer([:positive])}")

    key = "shared-session"

    on_exit(fn ->
      SessionManager.invalidate(key, workspace: workspace_a)
      SessionManager.invalidate(key, workspace: workspace_b)
      File.rm_rf!(workspace_a)
      File.rm_rf!(workspace_b)
    end)

    session_a =
      Session.new(key)
      |> Session.add_message("user", "from workspace a")

    session_b =
      Session.new(key)
      |> Session.add_message("user", "from workspace b")

    :ok = Session.save(session_a, workspace: workspace_a)
    :ok = Session.save(session_b, workspace: workspace_b)

    assert SessionManager.get_or_create(key, workspace: workspace_a).messages
           |> hd()
           |> Map.get("content") ==
             "from workspace a"

    assert SessionManager.get_or_create(key, workspace: workspace_b).messages
           |> hd()
           |> Map.get("content") ==
             "from workspace b"
  end

  defp session_path_for(key, workspace) do
    Session.messages_path(key, workspace: workspace)
  end
end
