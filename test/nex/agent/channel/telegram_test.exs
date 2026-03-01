defmodule Nex.Agent.Channel.TelegramTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Telegram

  setup do
    stop_if_running(Nex.Agent.Channel.Telegram)
    stop_if_running(Nex.Agent.Bus)

    {:ok, _} = Bus.start_link()

    on_exit(fn ->
      stop_if_running(Nex.Agent.Channel.Telegram)
      stop_if_running(Nex.Agent.Bus)
    end)

    :ok
  end

  test "publishes inbound telegram message when sender is allowed" do
    {:ok, seq} = Agent.start_link(fn -> 0 end)

    get_fun = fn _url, _params ->
      n = Agent.get_and_update(seq, fn current -> {current, current + 1} end)

      result =
        case n do
          0 ->
            []

          _ ->
            [
              %{
                "update_id" => 101,
                "message" => %{
                  "message_id" => 77,
                  "text" => "hello tg",
                  "chat" => %{"id" => 1001},
                  "from" => %{"id" => 42, "username" => "alice"}
                }
              }
            ]
        end

      {:ok, %{"ok" => true, "result" => result}}
    end

    post_fun = fn _url, _body -> {:ok, %{"ok" => true, "result" => true}} end

    config =
      Config.default()
      |> Config.set(:provider, "ollama")
      |> Config.set(:telegram_enabled, true)
      |> Config.set(:telegram_token, "123:abc")
      |> Config.set(:telegram_allow_from, ["42"])

    {:ok, pid} =
      Telegram.start_link(
        config: config,
        http_get_fun: get_fun,
        http_post_fun: post_fun,
        poll_interval_ms: 5_000
      )

    Bus.subscribe(:inbound)

    send(pid, :poll)

    assert_receive {:bus_message, :inbound, inbound}, 1_000
    assert inbound.channel == "telegram"
    assert inbound.chat_id == "1001"
    assert inbound.content == "hello tg"
    assert inbound.sender_id == "42|alice"
    assert inbound.message_id == 77
  end

  test "outbound supports reply_to_message metadata" do
    get_fun = fn _url, _params -> {:ok, %{"ok" => true, "result" => []}} end

    test_pid = self()

    post_fun = fn _url, body ->
      send(test_pid, {:telegram_post, body})
      {:ok, %{"ok" => true, "result" => true}}
    end

    config =
      Config.default()
      |> Config.set(:provider, "ollama")
      |> Config.set(:telegram_enabled, true)
      |> Config.set(:telegram_token, "123:abc")
      |> Config.set(:telegram_reply_to_message, true)

    {:ok, _pid} =
      Telegram.start_link(
        config: config,
        http_get_fun: get_fun,
        http_post_fun: post_fun,
        poll_interval_ms: 5_000
      )

    Telegram.send_message("2002", "reply text", %{"message_id" => 9})

    assert_receive {:telegram_post, body}, 1_000
    assert body.chat_id == "2002"
    assert body.text == "reply text"
    assert body.reply_to_message_id == 9
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
