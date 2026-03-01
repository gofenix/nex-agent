defmodule Nex.Agent.InboundWorkerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config, InboundWorker}

  setup do
    stop_if_running(Nex.Agent.InboundWorker)
    stop_if_running(Nex.Agent.Bus)

    {:ok, _} = Bus.start_link()

    on_exit(fn ->
      stop_if_running(Nex.Agent.InboundWorker)
      stop_if_running(Nex.Agent.Bus)
    end)

    :ok
  end

  test "reuses per-chat session agent and publishes telegram outbound" do
    {:ok, start_count} = Agent.start_link(fn -> 0 end)

    start_fun = fn _opts ->
      Agent.update(start_count, &(&1 + 1))
      {:ok, %{session: :s1}}
    end

    prompt_fun = fn _agent, content ->
      {:ok, "echo: #{content}", %{session: :s1}}
    end

    abort_fun = fn _agent -> :ok end

    config = Config.default() |> Config.set(:provider, "ollama")

    {:ok, _} =
      InboundWorker.start_link(
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
    prompt_fun = fn _agent, content -> {:ok, content, %{session: :x}} end

    abort_fun = fn _agent ->
      Agent.update(aborted, &(&1 + 1))
      :ok
    end

    config = Config.default() |> Config.set(:provider, "ollama")

    {:ok, _} =
      InboundWorker.start_link(
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
    assert stop_msg.content == "Stopped current task."

    Bus.publish(:inbound, Map.put(base, :content, "/new"))
    assert_receive {:bus_message, :telegram_outbound, new_msg}, 1_000
    assert new_msg.content == "New session started."

    assert Agent.get(aborted, & &1) == 1
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
