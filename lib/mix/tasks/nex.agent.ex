defmodule Mix.Tasks.Nex.Agent do
  @moduledoc """
  Nex Agent CLI
  """

  use Mix.Task

  @shortdoc "Nex Agent CLI"

  def run(args) do
    # Ensure Finch is started for HTTP requests
    ensure_finch_started()

    {opts, args} =
      OptionParser.parse!(args,
        switches: [message: :string, model: :string, provider: :string, help: :boolean],
        aliases: [m: :message, h: :help]
      )

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    cond do
      args == ["onboard"] -> run_onboard()
      args == ["status"] -> run_status()
      args == ["gateway"] -> run_gateway()
      List.starts_with?(args, ["config"]) -> run_config(args)
      opts[:message] != nil -> run_single(opts)
      true -> run_interactive()
    end
  end

  defp ensure_finch_started do
    case Process.whereis(Req.Finch) do
      nil ->
        {:ok, _} = Finch.start_link(name: Req.Finch)

      _ ->
        :ok
    end
  end

  defp print_help do
    Mix.shell().info("Nex Agent CLI")
    Mix.shell().info("  mix nex.agent                  Interactive REPL")
    Mix.shell().info("  mix nex.agent onboard          Initialize")
    Mix.shell().info("  mix nex.agent -m \"hello\"       Single message")
    Mix.shell().info("  mix nex.agent gateway          Start gateway")
    Mix.shell().info("  mix nex.agent status           Show status")
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
    Nex.Agent.Gateway.start()
    Process.sleep(:infinity)
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
