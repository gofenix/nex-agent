defmodule Nex.Agent.AdminTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Admin, Audit, Bus, CodeUpgrade, Session, Workspace}
  alias Nex.Agent.Tool.CustomTools

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-admin-#{System.unique_integer([:positive])}")

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

    assert Enum.map(overview_state.recent_sessions, & &1.key) == [
             "empty-session",
             "older-session"
           ]

    assert Enum.at(overview_state.recent_sessions, 0).last_message == nil
  end

  test "sessions_state preserves real session keys from metadata", %{workspace: workspace} do
    session =
      Session.new("telegram:123")
      |> Session.add_message("user", "hello from telegram")
      |> put_session_timestamps(~N[2026-03-30 09:00:00])

    assert :ok = Session.save(session, workspace: workspace)

    sessions_state = Admin.sessions_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert Enum.map(sessions_state.sessions, & &1.key) == ["telegram:123"]
    assert sessions_state.selected_session.key == "telegram:123"
    refute Enum.any?(sessions_state.sessions, &(&1.key == "telegram_123"))

    assert Enum.map(overview_state.recent_sessions, & &1.key) == ["telegram:123"]
  end

  test "skills_state and overview_state skip malformed runtime run logs", %{workspace: workspace} do
    runs_dir = Path.join(workspace, "skill_runtime/runs")
    File.mkdir_p!(runs_dir)

    File.write!(Path.join(runs_dir, "broken.jsonl"), "{bad json}\n")

    mixed_lines = [
      Jason.encode!(%{
        "type" => "run_started",
        "run_id" => "run-123",
        "prompt" => "select tools",
        "inserted_at" => "2026-03-30T12:00:00Z"
      }),
      "{bad json}",
      Jason.encode!(%{
        "type" => "skills_selected",
        "run_id" => "run-123",
        "packages" => ["core.weather"],
        "inserted_at" => "2026-03-30T12:00:01Z"
      }),
      Jason.encode!(%{
        "type" => "run_completed",
        "run_id" => "run-123",
        "status" => "ok",
        "result" => "done",
        "inserted_at" => "2026-03-30T12:00:02Z"
      })
    ]

    File.write!(Path.join(runs_dir, "mixed.jsonl"), Enum.join(mixed_lines, "\n"))

    skills_state = Admin.skills_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert length(skills_state.recent_runs) == 1

    assert hd(skills_state.recent_runs) == %{
             run_id: "run-123",
             prompt: "select tools",
             inserted_at: "2026-03-30T12:00:00Z",
             status: "ok",
             result: "done",
             packages: ["core.weather"]
           }

    assert overview_state.skills.recent_runs == 1
  end

  test "audit append broadcasts normalized admin event", %{workspace: workspace} do
    assert :ok = Admin.subscribe_events(self())

    assert :ok =
             Audit.append("runtime.gateway_started", %{"source" => "test"}, workspace: workspace)

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

  test "code_state includes custom tool modules and reads their source" do
    custom_tools_path =
      Path.join(System.tmp_dir!(), "nex-agent-custom-tools-#{System.unique_integer([:positive])}")

    previous_custom_tools_path = Application.get_env(:nex_agent, :custom_tools_path)
    Application.put_env(:nex_agent, :custom_tools_path, custom_tools_path)

    on_exit(fn ->
      if previous_custom_tools_path do
        Application.put_env(:nex_agent, :custom_tools_path, previous_custom_tools_path)
      else
        Application.delete_env(:nex_agent, :custom_tools_path)
      end

      File.rm_rf!(custom_tools_path)
    end)

    tool_name = "console_probe"
    tool_module = "Nex.Agent.Tool.Custom.ConsoleProbe"
    tool_dir = Path.join(custom_tools_path, tool_name)
    File.mkdir_p!(tool_dir)

    File.write!(
      Path.join(tool_dir, "tool.json"),
      Jason.encode!(%{
        "name" => tool_name,
        "module" => tool_module,
        "description" => "Console probe"
      })
    )

    File.write!(
      Path.join(tool_dir, "tool.ex"),
      """
      defmodule #{tool_module} do
        @behaviour Nex.Agent.Tool.Behaviour

        def name, do: "#{tool_name}"
        def definition, do: %{"name" => "#{tool_name}"}
        def execute(_args, _context), do: {:ok, %{"status" => "ok"}}
      end
      """
    )

    state = Admin.code_state()
    selected = Admin.code_state(module: tool_module)

    assert tool_module in state.modules
    assert selected.selected_module == tool_module
    assert selected.current_source =~ "defmodule #{tool_module} do"
    assert selected.current_source_preview =~ "defmodule #{tool_module} do"

    assert CodeUpgrade.source_path(CustomTools.module_for_name(tool_name)) ==
             Path.join(tool_dir, "tool.ex")
  end

  defp put_session_timestamps(session, naive_datetime) do
    timestamp = DateTime.from_naive!(naive_datetime, "Etc/UTC")
    %{session | created_at: timestamp, updated_at: timestamp}
  end
end
