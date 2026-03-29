defmodule Nex.Agent.AdminTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Admin, Audit, Bus, CodeUpgrade, Session, Workspace}

  setup do
    workspace = Path.join(System.tmp_dir!(), "nex-agent-admin-#{System.unique_integer([:positive])}")
    Workspace.ensure!(workspace: workspace)

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    on_exit(fn ->
      Bus.unsubscribe(:admin_events)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "sessions_state and overview_state tolerate empty sessions and sort by updated_at", %{
    workspace: workspace
  } do
    empty_session =
      Session.new("empty-session")
      |> put_session_timestamps(~N[2026-03-29 12:00:00])

    older_session =
      Session.new("older-session")
      |> Session.add_message("user", "older message")
      |> put_session_timestamps(~N[2026-03-29 10:00:00])

    assert :ok = Session.save(empty_session, workspace: workspace)
    assert :ok = Session.save(older_session, workspace: workspace)

    sessions_state = Admin.sessions_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert Enum.map(sessions_state.sessions, & &1.key) == ["empty-session", "older-session"]
    assert sessions_state.selected_session.key == "empty-session"
    assert sessions_state.selected_session.total_messages == 0

    assert Enum.map(overview_state.recent_sessions, & &1.key) == ["empty-session", "older-session"]
    assert Enum.at(overview_state.recent_sessions, 0).last_message == nil
  end

  test "audit append broadcasts normalized admin event", %{workspace: workspace} do
    assert :ok = Admin.subscribe_events(self())
    assert :ok = Audit.append("runtime.gateway_started", %{"source" => "test"}, workspace: workspace)

    assert_receive {:bus_message, :admin_events, event}
    assert event["topic"] == "runtime"
    assert event["kind"] == "runtime.gateway_started"
    assert event["summary"] == "Gateway started"
    assert event["payload"] == %{"source" => "test"}
  end

  test "code upgrade source path resolves project source files" do
    path = CodeUpgrade.source_path(Nex.Agent.Admin)

    assert File.exists?(path)
    assert String.ends_with?(path, "/lib/nex/agent/admin.ex")
  end

  defp put_session_timestamps(session, naive_datetime) do
    timestamp = DateTime.from_naive!(naive_datetime, "Etc/UTC")
    %{session | created_at: timestamp, updated_at: timestamp}
  end
end
