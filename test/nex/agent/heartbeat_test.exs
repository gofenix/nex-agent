defmodule Nex.Agent.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{CodeUpgrade, Heartbeat}

  setup do
    unique = System.unique_integer([:positive])
    workspace = Path.join(System.tmp_dir!(), "nex-agent-heartbeat-#{unique}")
    code_upgrades_path = Path.join(System.tmp_dir!(), "nex-agent-code-upgrades-#{unique}")
    heartbeat_name = String.to_atom("heartbeat_test_#{unique}")

    File.mkdir_p!(Path.join(workspace, "sessions"))
    File.mkdir_p!(Path.join(workspace, "memory"))

    Application.put_env(:nex_agent, :code_upgrades_path, code_upgrades_path)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    start_supervised!({Heartbeat, name: heartbeat_name, workspace: workspace, interval: 3600})
    :ok = GenServer.call(heartbeat_name, :start)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :code_upgrades_path)
      File.rm_rf!(workspace)
      File.rm_rf!(code_upgrades_path)
    end)

    {:ok, workspace: workspace, heartbeat_name: heartbeat_name}
  end

  test "heartbeat session GC removes stale session directories in the configured workspace", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    session_dir = Path.join(workspace, "sessions/stale-session")
    File.mkdir_p!(session_dir)
    File.write!(Path.join(session_dir, "messages.jsonl"), "{}\n")
    File.touch(session_dir, {{2020, 1, 1}, {0, 0, 0}})

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn -> not File.exists?(session_dir) end)
  end

  test "heartbeat archives stale daily logs in the configured workspace", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    date_dir = Path.join(workspace, "memory/2020-01-01")
    log_file = Path.join(date_dir, "log.md")
    archive_file = Path.join(workspace, "memory/archive/2020-01.md")

    File.mkdir_p!(date_dir)
    File.write!(log_file, "archived content")

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn -> File.exists?(archive_file) end)
    refute File.exists?(date_dir)
    assert File.read!(archive_file) =~ "# 2020-01-01"
    assert File.read!(archive_file) =~ "archived content"
  end

  test "heartbeat keeps only the latest code upgrade versions", %{heartbeat_name: heartbeat_name} do
    module_dir = Path.join(CodeUpgrade.versions_root(), "HeartbeatCleanup.Test")
    File.mkdir_p!(module_dir)
    File.write!(Path.join(module_dir, "backup.ex"), "backup")

    Enum.each(1..12, fn n ->
      path = Path.join(module_dir, "#{n}.ex")
      File.write!(path, ~s({"id":"#{n}","timestamp":"2026-03-18 00:00:00Z","code":"ok"}))
      File.touch!(path, {{2020, 1, n}, {0, 0, 0}})
    end)

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn -> count_version_files(module_dir) == 10 end)
    assert File.exists?(Path.join(module_dir, "backup.ex"))
    assert File.exists?(Path.join(module_dir, "12.ex"))
    refute File.exists?(Path.join(module_dir, "1.ex"))
    assert count_version_files(module_dir) == 10
  end

  test "heartbeat records daily evolution failures in execution history", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    config_path = Path.join(workspace, "heartbeat-config.json")
    write_test_config(config_path)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :config_path)
    end)

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn ->
             status = GenServer.call(heartbeat_name, :status)

             Enum.any?(status.recent_history, fn
               {"evolution", _timestamp, %{trigger: "scheduled_daily", result: {:error, _reason}}} ->
                 true

               _ ->
                 false
             end)
           end)
  end

  test "heartbeat does not advance weekly cooldown when weekly evolution fails", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    config_path = Path.join(workspace, "heartbeat-config.json")
    write_test_config(config_path)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :config_path)
    end)

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn ->
             state = :sys.get_state(heartbeat_name)

             Enum.any?(state.execution_history, fn
               {"evolution", _timestamp,
                %{trigger: "scheduled_weekly", result: {:error, _reason}}} ->
                 true

               _ ->
                 false
             end) and is_nil(state.last_weekly_evolution)
           end)
  end

  defp trigger_maintenance(heartbeat_name) do
    send(Process.whereis(heartbeat_name), :tick)
  end

  defp write_test_config(path) do
    File.write!(
      path,
      Jason.encode!(%{
        "provider" => "openai",
        "model" => "gpt-4o",
        "providers" => %{
          "openai" => %{
            "api_key" => "test-openai-key",
            "base_url" => "http://127.0.0.1:1"
          }
        }
      })
    )
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end

  defp count_version_files(module_dir) do
    module_dir
    |> File.ls!()
    |> Enum.filter(&(String.ends_with?(&1, ".ex") and &1 != "backup.ex"))
    |> length()
  end
end
