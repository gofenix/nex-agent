defmodule Mix.Tasks.Nex.Agent do
  @moduledoc """
  Nex Agent CLI
  """

  use Mix.Task

  @shortdoc "Nex Agent CLI"

  @gateway_pid_path Path.join(System.get_env("HOME", "."), ".nex/agent/gateway.pid")

  def run(args) do
    # Ensure Finch is started for HTTP requests
    ensure_finch_started()

    {opts, args} =
      OptionParser.parse!(args,
        switches: [
          message: :string,
          model: :string,
          provider: :string,
          help: :boolean,
          log: :boolean,
          log_level: :string
        ],
        aliases: [m: :message, h: :help, l: :log]
      )

    configure_logging(opts)

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    cond do
      args == ["onboard"] -> run_onboard()
      args == ["status"] -> run_status()
      args == ["gateway"] -> run_gateway()
      args == ["gateway", "stop"] -> run_gateway_stop()
      args == ["gateway", "restart"] -> run_gateway_restart()
      List.starts_with?(args, ["config"]) -> run_config(args)
      opts[:message] != nil -> run_single(opts)
      true -> run_interactive()
    end
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

  defp print_help do
    Mix.shell().info("Nex Agent CLI")
    Mix.shell().info("  mix nex.agent                  Interactive REPL")
    Mix.shell().info("  mix nex.agent onboard          Initialize")
    Mix.shell().info("  mix nex.agent -m \"hello\"       Single message")
    Mix.shell().info("  mix nex.agent gateway          Start gateway")
    Mix.shell().info("  mix nex.agent gateway stop     Stop gateway")
    Mix.shell().info("  mix nex.agent gateway restart  Restart gateway")
    Mix.shell().info("  mix nex.agent status           Show status")
    Mix.shell().info("  mix nex.agent gateway --log    Enable debug logs")
    Mix.shell().info("  mix nex.agent --log-level debug|info|warning|error")
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

  defp run_onboard do
    Mix.shell().info("Initializing Nex Agent...")
    Nex.Agent.Onboarding.ensure_initialized()
    Mix.shell().info("Workspace: #{Nex.Agent.Workspace.workspace_path()}")
    Mix.shell().info("Config:   #{Nex.Agent.Config.config_path()}")
  end

  defp run_status do
    config = Nex.Agent.Config.load()
    Mix.shell().info("Provider: #{config.provider}")
    Mix.shell().info("Model:    #{config.model}")
  end

  defp run_gateway do
    Mix.shell().info("Starting Gateway...")

    case stop_existing_gateway_if_present() do
      :ok -> :ok

      {:error, reason} ->
        Mix.shell().error("Failed to stop existing gateway: #{inspect(reason)}")
        System.halt(1)
    end

    lock_socket =
      case acquire_gateway_lock() do
        {:ok, socket} ->
          socket

        {:error, :already_running} ->
          Mix.shell().error("Gateway is already running (port lock is held).")
          System.halt(1)

        {:error, reason} ->
          Mix.shell().error("Failed to acquire gateway port lock: #{inspect(reason)}")
          System.halt(1)
      end

    case Process.whereis(Nex.Agent.Gateway) do
      nil ->
        {:ok, _} = Nex.Agent.Gateway.start_link()

      _pid ->
        :ok
    end

    persist_gateway_pid!()
    register_gateway_cleanup(lock_socket)
    Process.put(:gateway_lock_socket, lock_socket)
    Nex.Agent.Gateway.start()
    Process.sleep(:infinity)
  end

  defp run_gateway_stop do
    case stop_existing_gateway() do
      :ok -> Mix.shell().info("Gateway stopped")
      {:error, :not_running} -> Mix.shell().info("Gateway is not running")
      {:error, reason} -> Mix.raise("Failed to stop gateway: #{inspect(reason)}")
    end
  end

  defp run_gateway_restart do
    case stop_existing_gateway() do
      :ok -> Mix.shell().info("Existing gateway stopped")
      {:error, :not_running} -> Mix.shell().info("Gateway is not running, starting a new one")
      {:error, reason} -> Mix.raise("Failed to stop gateway: #{inspect(reason)}")
    end

    run_gateway()
  end

  defp acquire_gateway_lock do
    config = Nex.Agent.Config.load()
    gateway = config.gateway || %{}
    port = Map.get(gateway, "port", 18790)

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

  defp stop_existing_gateway do
    with {:ok, pid_string} <- read_gateway_pid(),
         {:ok, pid} <- parse_gateway_pid(pid_string),
         :ok <- signal_gateway(pid),
         :ok <- wait_for_gateway_exit(pid, 40) do
      delete_gateway_pid_file()
      :ok
    else
      {:error, :enoent} ->
        {:error, :not_running}

      {:error, :invalid_pid} ->
        delete_gateway_pid_file()
        {:error, :not_running}

      {:error, :not_running} ->
        delete_gateway_pid_file()
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_existing_gateway_if_present do
    case stop_existing_gateway() do
      :ok -> :ok
      {:error, :not_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_gateway_pid do
    case File.read(@gateway_pid_path) do
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

  defp persist_gateway_pid! do
    File.mkdir_p!(Path.dirname(@gateway_pid_path))
    File.write!(@gateway_pid_path, System.pid() <> "\n")
  end

  defp register_gateway_cleanup(lock_socket) do
    System.at_exit(fn _status ->
      cleanup_gateway_runtime(lock_socket)
    end)
  end

  defp cleanup_gateway_runtime(lock_socket) do
    _ = if is_port(lock_socket), do: :gen_tcp.close(lock_socket), else: :ok
    delete_gateway_pid_file()
  end

  defp delete_gateway_pid_file do
    case File.rm(@gateway_pid_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp run_config(args) do
    case args do
      ["config", "show"] ->
        config = Nex.Agent.Config.load()
        Mix.shell().info("Provider: #{config.provider}")
        Mix.shell().info("Model:    #{config.model}")

      ["config", "set", "provider", value] ->
        config = Nex.Agent.Config.load()
        Nex.Agent.Config.save(Nex.Agent.Config.set(config, :provider, value))
        Mix.shell().info("Updated provider = #{value}")

      ["config", "set", "model", value] ->
        config = Nex.Agent.Config.load()
        Nex.Agent.Config.save(Nex.Agent.Config.set(config, :model, value))
        Mix.shell().info("Updated model = #{value}")

      ["config", "set", "api_key", provider, key] ->
        config = Nex.Agent.Config.load()
        Nex.Agent.Config.save(Nex.Agent.Config.set(config, :api_key, {provider, key}))
        Mix.shell().info("Updated #{provider} API key")

      ["config", "set", "telegram.token", value] ->
        config = Nex.Agent.Config.load()
        Nex.Agent.Config.save(Nex.Agent.Config.set(config, :telegram_token, value))
        Mix.shell().info("Updated telegram.token")

      ["config", "set", "telegram.enabled", value] ->
        config = Nex.Agent.Config.load()

        case parse_boolean(value) do
          {:ok, bool} ->
            Nex.Agent.Config.save(Nex.Agent.Config.set(config, :telegram_enabled, bool))
            Mix.shell().info("Updated telegram.enabled = #{bool}")

          :error ->
            Mix.shell().error("Invalid boolean: #{value} (expected true/false)")
        end

      ["config", "set", "telegram.allow_from", value] ->
        config = Nex.Agent.Config.load()
        allow_from = parse_csv_list(value)
        Nex.Agent.Config.save(Nex.Agent.Config.set(config, :telegram_allow_from, allow_from))
        Mix.shell().info("Updated telegram.allow_from = #{Enum.join(allow_from, ",")}")

      ["config", "set", "telegram.reply_to_message", value] ->
        config = Nex.Agent.Config.load()

        case parse_boolean(value) do
          {:ok, bool} ->
            Nex.Agent.Config.save(Nex.Agent.Config.set(config, :telegram_reply_to_message, bool))
            Mix.shell().info("Updated telegram.reply_to_message = #{bool}")

          :error ->
            Mix.shell().error("Invalid boolean: #{value} (expected true/false)")
        end

      _ ->
        Mix.shell().error("Unknown config command")
    end
  end

  defp parse_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp parse_csv_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp run_single(opts) do
    config = Nex.Agent.Config.load()

    unless Nex.Agent.Config.valid?(config) do
      Mix.shell().error("No API key. Run: mix nex.agent onboard")
      System.halt(1)
    end

    Nex.Agent.Onboarding.ensure_initialized()

    {:ok, agent} =
      Nex.Agent.start(
        provider: String.to_atom(config.provider),
        model: config.model,
        api_key: Nex.Agent.Config.get_current_api_key(config),
        base_url: Nex.Agent.Config.get_current_base_url(config)
      )

    {:ok, result, _} = Nex.Agent.prompt(agent, opts[:message])
    Mix.shell().info(result)
  end

  defp run_interactive do
    config = Nex.Agent.Config.load()

    unless Nex.Agent.Config.valid?(config) do
      Mix.shell().error("No API key. Run: mix nex.agent onboard")
      System.halt(1)
    end

    Nex.Agent.Onboarding.ensure_initialized()

    Mix.shell().info("Nex Agent (type 'exit' to quit)")

    {:ok, agent} =
      Nex.Agent.start(
        provider: String.to_atom(config.provider),
        model: config.model,
        api_key: Nex.Agent.Config.get_current_api_key(config),
        base_url: Nex.Agent.Config.get_current_base_url(config)
      )

    loop(agent)
  end

  defp loop(agent) do
    case Mix.shell().prompt("You> ") do
      :eof ->
        Mix.shell().info("Goodbye!")

      input ->
        input = String.trim(input)

        if input in ["exit", "quit"] do
          Mix.shell().info("Goodbye!")
        else
          if input != "" do
            {:ok, result, _} = Nex.Agent.prompt(agent, input)
            Mix.shell().info(result)
          end

          loop(agent)
        end
    end
  end
end
