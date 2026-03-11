defmodule Nex.Agent.InboundWorkerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config, InboundWorker}

  setup do
    # Ensure required services are running (started by Application supervisor,
    # but may have been stopped by prior test cascading)
    ensure_started(Nex.Agent.Bus, fn -> Bus.start_link() end)
    ensure_started(Nex.Agent.SessionManager, fn -> Nex.Agent.SessionManager.start_link() end)

    ensure_started(Nex.Agent.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Nex.Agent.TaskSupervisor)
    end)

    # Stop the application-managed InboundWorker so we can start our own with mocks
    stop_if_running(Nex.Agent.InboundWorker)

    on_exit(fn ->
      stop_if_running(Nex.Agent.InboundWorker)
    end)

    :ok
  end

  test "reuses per-chat session agent and publishes telegram outbound" do
    {:ok, start_count} = Agent.start_link(fn -> 0 end)

    start_fun = fn _opts ->
      Agent.update(start_count, &(&1 + 1))
      {:ok, %{session: :s1}}
    end

    prompt_fun = fn _agent, content, _opts ->
      {:ok, "echo: #{content}", %{session: :s1}}
    end

    abort_fun = fn _agent -> :ok end

    config = Config.default() |> Config.set(:provider, "ollama")

    assert_start_worker(
      config: config,
      agent_start_fun: start_fun,
      agent_prompt_fun: prompt_fun,
      agent_abort_fun: abort_fun
    )

    Bus.subscribe(:telegram_outbound)

    payload = %{
      channel: "telegram",
      chat_id: "100",
      sender_id: "42|alice",
      content: "first",
      message_id: 1,
      metadata: %{"message_id" => 1}
    }

    Bus.publish(:inbound, payload)

    assert_receive {:bus_message, :telegram_outbound, out1}, 1_000
    assert out1.chat_id == "100"
    assert out1.content == "echo: first"

    Bus.publish(:inbound, %{
      payload
      | content: "second",
        message_id: 2,
        metadata: %{"message_id" => 2}
    })

    assert_receive {:bus_message, :telegram_outbound, out2}, 1_000
    assert out2.content == "echo: second"

    assert Agent.get(start_count, & &1) == 1
  end

  test "supports /new and /stop control commands" do
    {:ok, aborted} = Agent.start_link(fn -> 0 end)

    start_fun = fn _opts -> {:ok, %{session: :x}} end
    prompt_fun = fn _agent, content, _opts -> {:ok, content, %{session: :x}} end

    abort_fun = fn _agent ->
      Agent.update(aborted, &(&1 + 1))
      :ok
    end

    config = Config.default() |> Config.set(:provider, "ollama")

    assert_start_worker(
      config: config,
      agent_start_fun: start_fun,
      agent_prompt_fun: prompt_fun,
      agent_abort_fun: abort_fun
    )

    Bus.subscribe(:telegram_outbound)

    base = %{channel: "telegram", chat_id: "200", sender_id: "8|bob", metadata: %{}}

    Bus.publish(:inbound, Map.put(base, :content, "hello"))
    assert_receive {:bus_message, :telegram_outbound, _}, 1_000

    Bus.publish(:inbound, Map.put(base, :content, "/stop"))
    assert_receive {:bus_message, :telegram_outbound, stop_msg}, 1_000
    assert stop_msg.content == "Stopped 0 task(s)."

    Bus.publish(:inbound, Map.put(base, :content, "/new"))
    assert_receive {:bus_message, :telegram_outbound, new_msg}, 1_000
    assert new_msg.content == "New session started."

    assert Agent.get(aborted, & &1) == 1
  end

  defp ensure_started(name, start_fn) do
    unless Process.whereis(name) do
      case start_fn.() do
        {:ok, pid} ->
          Process.unlink(pid)
          {:ok, pid}

        other ->
          other
      end
    end
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

  defp assert_start_worker(opts) do
    case InboundWorker.start_link(opts) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
