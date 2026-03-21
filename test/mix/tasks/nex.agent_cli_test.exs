defmodule Mix.Tasks.Nex.AgentCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Nex.Agent.Config

  @env_keys [:config_path, :workspace_path, :agent_base_dir]

  setup do
    previous =
      Enum.map(@env_keys, fn key ->
        {key, Application.get_env(:nex_agent, key, :__unset__)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :__unset__} -> Application.delete_env(:nex_agent, key)
        {key, value} -> Application.put_env(:nex_agent, key, value)
      end)
    end)

    :ok
  end

  test "--help only exposes the host-shell surface" do
    output =
      capture_io(fn ->
        Mix.Tasks.Nex.Agent.run(["--help"])
      end)

    assert output =~ "mix nex.agent [--config PATH] [--workspace PATH]"
    assert output =~ "mix nex.agent gateway restart [--config PATH] [--workspace PATH]"
    assert output =~ "-c, --config PATH"
    assert output =~ "-w, --workspace PATH"
    refute output =~ "mix nex.agent tasks"
    refute output =~ "mix nex.agent summary"
    refute output =~ "mix nex.agent executors"
    refute output =~ "mix nex.agent capture"
  end

  test "unknown commands print help and do not fall through to REPL" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Nex.Agent.run(["definitely-unknown"])
        end
      end)

    assert output =~ "Nex Agent CLI"
    assert output =~ "mix nex.agent gateway"
    refute output =~ "Nex Agent (type 'exit' to quit)"
  end

  test "onboard with explicit config and workspace persists instance targeting" do
    base_dir = temp_dir("cli-onboard")
    config_path = Path.join(base_dir, "alpha/config.json")
    workspace = Path.join(base_dir, "alpha-workspace")

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Nex.Agent.run(["-c", config_path, "-w", workspace, "onboard"])
      end)

    config = Config.load(config_path: config_path)

    assert File.exists?(config_path)
    assert File.exists?(Path.join(workspace, "AGENTS.md"))
    assert Config.configured_workspace(config) == Path.expand(workspace)
    assert output =~ "Config:    #{Path.expand(config_path)}"
    assert output =~ "Workspace: #{Path.expand(workspace)}"
  end

  test "config show and config set operate on the targeted instance" do
    base_dir = temp_dir("cli-config")
    config_path = Path.join(base_dir, "beta/config.json")
    workspace = Path.join(base_dir, "beta-workspace")

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    File.mkdir_p!(Path.dirname(config_path))

    config =
      Config.default()
      |> Config.set(:provider, "ollama")
      |> Config.set(:model, "llama3.1")
      |> Config.set(:default_workspace, Path.expand(workspace))
      |> Config.set(:gateway_port, 19_321)

    :ok = Config.save(config, config_path: config_path)

    output =
      capture_io(fn ->
        Mix.Tasks.Nex.Agent.run(["-c", config_path, "config", "show"])
      end)

    assert output =~ "Config: #{Path.expand(config_path)}"
    assert output =~ "Workspace: #{Path.expand(workspace)}"
    assert output =~ "Provider: ollama"
    assert output =~ "Model: llama3.1"
    assert output =~ "Gateway port: 19321"

    new_workspace = Path.join(base_dir, "gamma-workspace")

    capture_io(fn ->
      Mix.Tasks.Nex.Agent.run([
        "-c",
        config_path,
        "config",
        "set",
        "defaults.workspace",
        new_workspace
      ])
    end)

    capture_io(fn ->
      Mix.Tasks.Nex.Agent.run(["-c", config_path, "config", "set", "gateway.port", "19444"])
    end)

    updated = Config.load(config_path: config_path)
    assert Config.configured_workspace(updated) == Path.expand(new_workspace)
    assert Config.gateway_port(updated) == 19_444
  end

  test "single-message mode honors -m instead of falling through to the REPL" do
    base_dir = temp_dir("cli-message")
    config_path = Path.join(base_dir, "msg/config.json")
    workspace = Path.join(base_dir, "msg-workspace")

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    File.mkdir_p!(Path.dirname(config_path))

    config =
      Config.default()
      |> Map.put(:provider, "openai")
      |> Map.put(:model, "gpt-4o")
      |> Map.put(:providers, %{
        "openai" => %{
          "api_key" => "test-key",
          "base_url" => "http://127.0.0.1:1/v1"
        }
      })
      |> Map.put(:defaults, %{"workspace" => Path.expand(workspace)})

    :ok = Config.save(config, config_path: config_path)

    output =
      capture_io("exit\n", fn ->
        assert_raise MatchError, fn ->
          Mix.Tasks.Nex.Agent.run(["-c", config_path, "-w", workspace, "-m", "hello"])
        end
      end)

    refute output =~ "Nex Agent (type 'exit' to quit)"
    refute output =~ "Goodbye!"
  end

  test "gateway stop only targets the selected instance pid file" do
    base_dir = temp_dir("cli-gateway")
    config_a = Path.join(base_dir, "a/config.json")
    config_b = Path.join(base_dir, "b/config.json")

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    File.mkdir_p!(Path.dirname(config_a))
    File.mkdir_p!(Path.dirname(config_b))

    pid_a = spawn_sleep_process()
    pid_b = spawn_sleep_process()

    on_exit(fn ->
      kill_process(pid_a)
      kill_process(pid_b)
    end)

    File.write!(Path.join(Path.dirname(config_a), "gateway.pid"), "#{pid_a}\n")
    File.write!(Path.join(Path.dirname(config_b), "gateway.pid"), "#{pid_b}\n")

    output =
      capture_io(fn ->
        Mix.Tasks.Nex.Agent.run(["-c", config_a, "gateway", "stop"])
      end)

    assert output =~ "Gateway stopped"
    refute process_alive?(pid_a)
    assert process_alive?(pid_b)
    refute File.exists?(Path.join(Path.dirname(config_a), "gateway.pid"))
    assert File.exists?(Path.join(Path.dirname(config_b), "gateway.pid"))
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp spawn_sleep_process do
    {output, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    {pid, ""} = output |> String.trim() |> Integer.parse()
    pid
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp kill_process(pid) do
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
