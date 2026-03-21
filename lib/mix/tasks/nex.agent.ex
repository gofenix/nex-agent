defmodule Mix.Tasks.Nex.Agent do
  @moduledoc """
  Nex Agent CLI
  """

  use Mix.Task

  alias Nex.Agent.{Config, Gateway, Onboarding, Workspace}

  @shortdoc "Nex Agent CLI"

  @target_env_keys [:config_path, :workspace_path, :agent_base_dir]
  @switches [
    message: :string,
    model: :string,
    provider: :string,
    config: :string,
    workspace: :string,
    help: :boolean,
    log: :boolean,
    log_level: :string
  ]
  @aliases [m: :message, c: :config, w: :workspace, h: :help, l: :log]

  def run(args) do
    ensure_finch_started()

    {opts, positional} = OptionParser.parse!(args, switches: @switches, aliases: @aliases)

    configure_logging(opts)

    if opts[:help] do
      print_help()
    else
      dispatch(positional, opts)
    end
  end

  defp dispatch([], %{message: message} = opts) when is_binary(message) and message != "" do
    with_cli_targeting(opts, fn target -> run_single(opts, target) end)
  end

  defp dispatch([], opts) do
    with_cli_targeting(opts, &run_interactive/1)
  end

  defp dispatch(["onboard"], opts) do
    with_cli_targeting(opts, &run_onboard/1)
  end

  defp dispatch(["status"], opts) do
    with_cli_targeting(opts, &run_status/1)
  end

  defp dispatch(["gateway"], opts) do
    with_cli_targeting(opts, &run_gateway/1)
  end

  defp dispatch(["gateway", "stop"], opts) do
    with_cli_targeting(opts, &run_gateway_stop/1)
  end

  defp dispatch(["gateway", "restart"], opts) do
    with_cli_targeting(opts, &run_gateway_restart/1)
  end

  defp dispatch(["config" | _] = args, opts) do
    with_config_targeting(opts, fn target -> run_config(args, target) end)
  end

  defp dispatch(args, _opts) do
    print_help()
    Mix.raise("Unknown command: #{Enum.join(args, " ")}")
  end

  defp ensure_finch_started do
    case Application.ensure_all_started(:req) do
      {:ok, _apps} ->
        :ok

      {:error, {:already_started, _app}} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start :req application: #{inspect(reason)}")
    end
  end

  defp ensure_app_started do
    case Application.ensure_all_started(:nex_agent) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, reason} -> Mix.raise("Failed to start :nex_agent application: #{inspect(reason)}")
    end
  end

  defp print_help do
    Mix.shell().info("Nex Agent CLI")
    Mix.shell().info("  mix nex.agent [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent -m \"hello\" [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent onboard [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent status [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent gateway [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent gateway stop [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent gateway restart [--config PATH] [--workspace PATH]")
    Mix.shell().info("  mix nex.agent config show [--config PATH]")
    Mix.shell().info("  mix nex.agent config set provider VALUE [--config PATH]")
    Mix.shell().info("  mix nex.agent config set model VALUE [--config PATH]")
    Mix.shell().info("  mix nex.agent config set api_key PROVIDER KEY [--config PATH]")
    Mix.shell().info("  mix nex.agent config set defaults.workspace PATH [--config PATH]")
    Mix.shell().info("  mix nex.agent config set gateway.port PORT [--config PATH]")
    Mix.shell().info("")
    Mix.shell().info("Global options:")
    Mix.shell().info("  -c, --config PATH      Use a specific config file")
    Mix.shell().info("  -w, --workspace PATH   Use a specific workspace")
    Mix.shell().info("  -m, --message TEXT     Send a single message")
    Mix.shell().info("  --log                  Enable debug logs")
    Mix.shell().info("  --log-level LEVEL      debug|info|warning|error")
  end

  defp configure_logging(opts) do
    level =
      cond do
        is_binary(opts[:log_level]) -> parse_log_level(opts[:log_level])
        opts[:log] == true -> :debug
        true -> nil
      end

    if level do
      Logger.configure(level: level)
      Mix.shell().info("Logger level set to #{level}")
    end
  end

  defp parse_log_level(raw) do
    case raw |> String.trim() |> String.downcase() do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  defp run_onboard(target) do
    Mix.shell().info("Initializing Nex Agent...")
    :ok = Onboarding.ensure_initialized()
    :ok = Onboarding.ensure_workspace_initialized(target.workspace)

    config =
      Config.load()
      |> Config.set(:default_workspace, target.workspace)

    :ok = Config.save(config)

    Mix.shell().info("Workspace: #{target.workspace}")
    Mix.shell().info("Config:    #{target.config_path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  mix nex.agent config show")
    Mix.shell().info("  mix nex.agent config set provider <provider>")
    Mix.shell().info("  mix nex.agent config set model <model>")
    Mix.shell().info("  mix nex.agent config set api_key <provider> <key>")
    Mix.shell().info("  mix nex.agent gateway")
  end

  defp run_status(target) do
    config = Config.load()
    gateway_running = gateway_running?(target)

    Mix.shell().info("Config: #{target.config_path}")
    Mix.shell().info("Workspace: #{target.workspace}")
    Mix.shell().info("Provider: #{config.provider}")
    Mix.shell().info("Model: #{config.model}")
    Mix.shell().info("Gateway port: #{Config.gateway_port(config)}")
    Mix.shell().info("Gateway: #{if(gateway_running, do: "running", else: "stopped")}")
    Mix.shell().info("Enabled channels: #{enabled_channels(config) |> format_list()}")

    if Process.whereis(Nex.Agent.Gateway) do
      services = Gateway.status().services

      Mix.shell().info("Core services:")

      Enum.each([:bus, :cron, :heartbeat, :tool_registry, :inbound_worker, :subagent], fn key ->
        Mix.shell().info(
          "  #{service_label(key)}: #{if(Map.get(services, key), do: "up", else: "down")}"
        )
      end)
    end
  end

  defp run_gateway(target) do
    Mix.shell().info("Starting Gateway...")

    case stop_existing_gateway_if_present(target) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Failed to stop existing gateway: #{inspect(reason)}")
        Mix.raise("Gateway startup aborted")
    end

    lock_socket =
      case acquire_gateway_lock() do
        {:ok, socket} ->
          socket

        {:error, :already_running} ->
          Mix.shell().error("Gateway is already running (port lock is held).")
          Mix.raise("Gateway startup aborted")

        {:error, reason} ->
          Mix.shell().error("Failed to acquire gateway port lock: #{inspect(reason)}")
          Mix.raise("Gateway startup aborted")
      end

    ensure_cli_runtime(target)

    persist_gateway_pid!(target)
    register_gateway_cleanup(lock_socket, target)
    Process.put(:gateway_lock_socket, lock_socket)

    case Gateway.start() do
      :ok ->
        Process.sleep(:infinity)

      {:error, reason} ->
        cleanup_gateway_runtime(lock_socket, target)
        Mix.raise("Failed to start gateway: #{inspect(reason)}")
    end
  end

  defp run_gateway_stop(target) do
    case stop_existing_gateway(target) do
      :ok -> Mix.shell().info("Gateway stopped")
      {:error, :not_running} -> Mix.shell().info("Gateway is not running")
      {:error, reason} -> Mix.raise("Failed to stop gateway: #{inspect(reason)}")
    end
  end

  defp run_gateway_restart(target) do
    case stop_existing_gateway(target) do
      :ok -> Mix.shell().info("Existing gateway stopped")
      {:error, :not_running} -> Mix.shell().info("Gateway is not running, starting a new one")
      {:error, reason} -> Mix.raise("Failed to stop gateway: #{inspect(reason)}")
    end

    run_gateway(target)
  end

  defp acquire_gateway_lock do
    config = Config.load()
    port = Config.gateway_port(config)

    :gen_tcp.listen(port, [
      :binary,
      {:packet, 0},
      {:active, false},
      {:reuseaddr, false},
      {:ip, {127, 0, 0, 1}}
    ])
    |> case do
      {:ok, socket} -> {:ok, socket}
      {:error, :eaddrinuse} -> {:error, :already_running}
      other -> other
    end
  end

  defp stop_existing_gateway(target) do
    with {:ok, pid_string} <- read_gateway_pid(target),
         {:ok, pid} <- parse_gateway_pid(pid_string),
         :ok <- signal_gateway(pid),
         :ok <- wait_for_gateway_exit(pid, 40) do
      delete_gateway_pid_file(target)
      :ok
    else
      {:error, :enoent} ->
        {:error, :not_running}

      {:error, :invalid_pid} ->
        delete_gateway_pid_file(target)
        {:error, :not_running}

      {:error, :not_running} ->
        delete_gateway_pid_file(target)
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_existing_gateway_if_present(target) do
    case stop_existing_gateway(target) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_gateway_pid(target) do
    case File.read(gateway_pid_path(target)) do
      {:ok, pid_string} -> {:ok, String.trim(pid_string)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_gateway_pid(pid_string) do
    case Integer.parse(pid_string) do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> {:error, :invalid_pid}
    end
  end

  defp signal_gateway(pid) do
    case System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :not_running}
    end
  end

  defp wait_for_gateway_exit(_pid, 0), do: {:error, :timeout}

  defp wait_for_gateway_exit(pid, attempts_left) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(100)
        wait_for_gateway_exit(pid, attempts_left - 1)

      {_output, _status} ->
        :ok
    end
  end

  defp persist_gateway_pid!(target) do
    path = gateway_pid_path(target)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, System.pid() <> "\n")
  end

  defp register_gateway_cleanup(lock_socket, target) do
    System.at_exit(fn _status ->
      cleanup_gateway_runtime(lock_socket, target)
    end)
  end

  defp cleanup_gateway_runtime(lock_socket, target) do
    _ = if is_port(lock_socket), do: :gen_tcp.close(lock_socket), else: :ok
    delete_gateway_pid_file(target)
  end

  defp delete_gateway_pid_file(target) do
    case File.rm(gateway_pid_path(target)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp gateway_running?(target) do
    with {:ok, pid_string} <- read_gateway_pid(target),
         {:ok, pid} <- parse_gateway_pid(pid_string),
         {_output, 0} <-
           System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  end

  defp gateway_pid_path(target) do
    Path.join(target.config_dir, "gateway.pid")
  end

  defp run_config(args, target) do
    case args do
      ["config", "show"] ->
        config = Config.load()
        Mix.shell().info("Config: #{target.config_path}")
        Mix.shell().info("Workspace: #{target.workspace}")
        Mix.shell().info("Provider: #{config.provider}")
        Mix.shell().info("Model: #{config.model}")
        Mix.shell().info("Gateway port: #{Config.gateway_port(config)}")

      ["config", "set", "provider", value] ->
        persist_config_update(:provider, value)
        Mix.shell().info("Updated provider = #{value}")

      ["config", "set", "model", value] ->
        persist_config_update(:model, value)
        Mix.shell().info("Updated model = #{value}")

      ["config", "set", "api_key", provider, key] ->
        persist_config_update(:api_key, {provider, key})
        Mix.shell().info("Updated #{provider} API key")

      ["config", "set", "defaults.workspace", value] ->
        workspace = Path.expand(value)
        persist_config_update(:default_workspace, workspace)
        Mix.shell().info("Updated defaults.workspace = #{workspace}")

      ["config", "set", "gateway.port", value] ->
        port = parse_positive_integer!(value, "gateway.port")
        persist_config_update(:gateway_port, port)
        Mix.shell().info("Updated gateway.port = #{port}")

      ["config", "set", "telegram.token", value] ->
        persist_config_update(:telegram_token, value)
        Mix.shell().info("Updated telegram.token")

      ["config", "set", "telegram.enabled", value] ->
        bool = parse_boolean!(value)
        persist_config_update(:telegram_enabled, bool)
        Mix.shell().info("Updated telegram.enabled = #{bool}")

      ["config", "set", "telegram.allow_from", value] ->
        allow_from = parse_csv_list(value)
        persist_config_update(:telegram_allow_from, allow_from)
        Mix.shell().info("Updated telegram.allow_from = #{Enum.join(allow_from, ",")}")

      ["config", "set", "telegram.reply_to_message", value] ->
        bool = parse_boolean!(value)
        persist_config_update(:telegram_reply_to_message, bool)
        Mix.shell().info("Updated telegram.reply_to_message = #{bool}")

      _ ->
        Mix.raise("Unknown config command")
    end
  end

  defp persist_config_update(key, value) do
    Config.load()
    |> Config.set(key, value)
    |> Config.save()
  end

  defp parse_boolean!(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> Mix.raise("Invalid boolean: #{value} (expected true/false)")
    end
  end

  defp parse_positive_integer!(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> Mix.raise("Invalid #{field}: #{value} (expected positive integer)")
    end
  end

  defp parse_csv_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp run_single(opts, target) do
    ensure_cli_runtime(target)
    config = Config.load()

    unless Config.valid?(config) do
      Mix.shell().error("No API key. Run: mix nex.agent onboard")
      Mix.raise("Invalid configuration")
    end

    {:ok, agent} =
      Nex.Agent.start(
        provider: Config.provider_to_atom(config.provider),
        model: config.model,
        api_key: Config.get_current_api_key(config),
        base_url: Config.get_current_base_url(config),
        tools: config.tools,
        workspace: target.workspace,
        max_iterations: Config.get_max_iterations(config)
      )

    {:ok, result, _} = Nex.Agent.prompt(agent, opts[:message], workspace: target.workspace)
    Mix.shell().info(result)
  end

  defp run_interactive(target) do
    ensure_cli_runtime(target)
    config = Config.load()

    unless Config.valid?(config) do
      Mix.shell().error("No API key. Run: mix nex.agent onboard")
      Mix.raise("Invalid configuration")
    end

    Mix.shell().info("Nex Agent (type 'exit' to quit)")

    {:ok, agent} =
      Nex.Agent.start(
        provider: Config.provider_to_atom(config.provider),
        model: config.model,
        api_key: Config.get_current_api_key(config),
        base_url: Config.get_current_base_url(config),
        tools: config.tools,
        workspace: target.workspace,
        max_iterations: Config.get_max_iterations(config)
      )

    loop(agent, target.workspace)
  end

  defp loop(agent, workspace) do
    case Mix.shell().prompt("You> ") do
      :eof ->
        Mix.shell().info("Goodbye!")

      input ->
        input = String.trim(input)

        if input in ["exit", "quit"] do
          Mix.shell().info("Goodbye!")
        else
          if input != "" do
            {:ok, result, _} = Nex.Agent.prompt(agent, input, workspace: workspace)
            Mix.shell().info(result)
          end

          loop(agent, workspace)
        end
    end
  end

  defp ensure_cli_runtime(target) do
    ensure_app_started()
    :ok = Onboarding.ensure_initialized()
    :ok = Onboarding.ensure_workspace_initialized(target.workspace)
  end

  defp with_cli_targeting(opts, fun) do
    target = resolve_target(opts, true)
    with_targeting(target, fn -> fun.(target) end)
  end

  defp with_config_targeting(opts, fun) do
    target = resolve_target(opts, false)
    with_targeting(target, fn -> fun.(target) end)
  end

  defp resolve_target(opts, consume_cli_workspace?) do
    config_path = resolve_config_path(opts)
    config = Config.load(config_path: config_path)
    workspace = resolve_workspace(opts, config_path, config, consume_cli_workspace?)

    %{
      config_path: config_path,
      config_dir: Path.dirname(config_path),
      workspace: workspace
    }
  end

  defp resolve_config_path(opts) do
    case opts[:config] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.expand(Config.default_config_path())
    end
  end

  defp resolve_workspace(opts, config_path, config, consume_cli_workspace?) do
    cli_workspace =
      if consume_cli_workspace? do
        case opts[:workspace] do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> nil
        end
      end

    cond do
      is_binary(cli_workspace) ->
        cli_workspace

      workspace = Config.configured_workspace(config) ->
        Path.expand(workspace)

      config_path != Path.expand(Config.default_config_path()) ->
        Path.expand(Path.join(Path.dirname(config_path), "workspace"))

      true ->
        Workspace.default_root()
    end
  end

  defp with_targeting(target, fun) do
    previous =
      Enum.map(@target_env_keys, fn key ->
        {key, Application.get_env(:nex_agent, key, :__unset__)}
      end)

    Application.put_env(:nex_agent, :config_path, target.config_path)
    Application.put_env(:nex_agent, :workspace_path, target.workspace)
    Application.put_env(:nex_agent, :agent_base_dir, target.config_dir)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, :__unset__} -> Application.delete_env(:nex_agent, key)
        {key, value} -> Application.put_env(:nex_agent, key, value)
      end)
    end
  end

  defp enabled_channels(config) do
    []
    |> maybe_enabled("telegram", Config.telegram_enabled?(config))
    |> maybe_enabled("feishu", Config.feishu_enabled?(config))
    |> maybe_enabled("discord", Config.discord_enabled?(config))
    |> maybe_enabled("slack", Config.slack_enabled?(config))
    |> maybe_enabled("dingtalk", Config.dingtalk_enabled?(config))
  end

  defp maybe_enabled(channels, name, true), do: channels ++ [name]
  defp maybe_enabled(channels, _name, false), do: channels

  defp format_list([]), do: "(none)"
  defp format_list(list), do: Enum.join(list, ", ")

  defp service_label(:bus), do: "Bus"
  defp service_label(:cron), do: "Cron"
  defp service_label(:heartbeat), do: "Heartbeat"
  defp service_label(:tool_registry), do: "Registry"
  defp service_label(:inbound_worker), do: "InboundWorker"
  defp service_label(:subagent), do: "Subagent"
end
