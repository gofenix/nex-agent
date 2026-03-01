defmodule Nex.Agent.GatewayTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Gateway

  setup do
    stop_if_running(Nex.Agent.Gateway)
    stop_if_running(Nex.Agent.InboundWorker)
    stop_if_running(Nex.Agent.Channel.Telegram)
    stop_if_running(Nex.Agent.Cron)
    stop_if_running(Nex.Agent.Bus)

    tmp_dir = Path.join(System.tmp_dir!(), "nex_agent_gateway_test")
    File.mkdir_p!(tmp_dir)
    config_path = Path.join(tmp_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "provider" => "ollama",
        "model" => "llama3.1",
        "providers" => %{
          "ollama" => %{"api_key" => nil, "base_url" => "http://localhost:11434"}
        },
        "telegram" => %{"enabled" => false}
      })
    )

    previous = Application.get_env(:nex_agent, :config_path)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      stop_if_running(Nex.Agent.Gateway)
      stop_if_running(Nex.Agent.InboundWorker)
      stop_if_running(Nex.Agent.Channel.Telegram)
      stop_if_running(Nex.Agent.Cron)
      stop_if_running(Nex.Agent.Bus)

      if previous do
        Application.put_env(:nex_agent, :config_path, previous)
      else
        Application.delete_env(:nex_agent, :config_path)
      end
    end)

    :ok
  end

  test "gateway start boots inbound worker and keeps telegram off when disabled" do
    start_supervised!({Gateway, name: Nex.Agent.Gateway})

    assert :ok == Gateway.start()

    status = Gateway.status()
    assert status.status == :running
    assert status.services.bus
    assert status.services.cron
    assert status.services.inbound_worker
    refute status.services.telegram_channel

    assert :ok == Gateway.stop()
  end

  defp stop_if_running(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
