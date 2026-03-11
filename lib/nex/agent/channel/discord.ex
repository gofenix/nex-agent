defmodule Nex.Agent.Channel.Discord do
  @moduledoc """
  Discord channel using Bot Gateway (WebSocket).

  Connects to Discord via the Gateway WebSocket API, receives MESSAGE_CREATE events,
  and sends replies via the REST API. Follows the same Bus pub/sub pattern as Telegram.

  ## Configuration

      %{
        "enabled" => true,
        "token" => "Bot MTIz...",       # Bot token (with "Bot " prefix)
        "allow_from" => ["channel_id"], # Allowed channel IDs (empty = all)
        "guild_id" => nil               # Optional: restrict to a guild
      }
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}

  @discord_api "https://discord.com/api/v10"
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @heartbeat_jitter 0.9
  @reconnect_delay_ms 5_000

  defstruct [
    :token,
    :allow_from,
    :guild_id,
    :enabled,
    :ws_pid,
    :ws_ref,
    :heartbeat_interval,
    :heartbeat_timer,
    :sequence,
    :session_id,
    :resume_gateway_url,
    :bot_user_id
  ]

  @type t :: %__MODULE__{
          token: String.t(),
          allow_from: [String.t()],
          guild_id: String.t() | nil,
          enabled: boolean(),
          ws_pid: pid() | nil,
          ws_ref: reference() | nil,
          heartbeat_interval: integer() | nil,
          heartbeat_timer: reference() | nil,
          sequence: integer() | nil,
          session_id: String.t() | nil,
          resume_gateway_url: String.t() | nil,
          bot_user_id: String.t() | nil
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), map()) :: :ok
  def send_message(channel_id, content, metadata \\ %{}) do
    Bus.publish(:discord_outbound, %{
      chat_id: to_string(channel_id),
      content: content,
      metadata: metadata
    })
  end

  # Server

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)
    _ = Application.ensure_all_started(:mint)

    config = Keyword.get(opts, :config, Config.load())
    discord = Config.discord(config)

    state = %__MODULE__{
      token: Map.get(discord, "token", ""),
      allow_from: Config.discord_allow_from(config),
      guild_id: Map.get(discord, "guild_id"),
      enabled: Config.discord_enabled?(config),
      sequence: nil,
      session_id: nil
    }

    Bus.subscribe(:discord_outbound)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_continue(:connect, %{token: ""} = state) do
    Logger.warning("[Discord] No token configured, disabling")
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_gateway(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Discord] Gateway connect failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send_ws(state.ws_pid, %{op: 1, d: state.sequence})
    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = close_ws(state)
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:ws_message, frame}, state) do
    case Jason.decode(frame) do
      {:ok, payload} ->
        state = handle_gateway_event(payload, state)
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ws_closed, _reason}, state) do
    Logger.warning("[Discord] WebSocket closed, reconnecting...")
    state = cancel_heartbeat(state)
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil}}
  end

  @impl true
  def handle_info({:bus_message, :discord_outbound, payload}, state) when is_map(payload) do
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    Logger.warning("[Discord] WS process down: #{inspect(reason)}")
    state = cancel_heartbeat(state)
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil, ws_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Gateway events

  defp handle_gateway_event(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    # Hello - start heartbeating and identify
    jittered = trunc(interval * @heartbeat_jitter)
    timer = Process.send_after(self(), :heartbeat, jittered)

    state = %{state | heartbeat_interval: interval, heartbeat_timer: timer}

    if state.session_id && state.sequence do
      # Resume
      send_ws(state.ws_pid, %{
        op: 6,
        d: %{
          token: state.token,
          session_id: state.session_id,
          seq: state.sequence
        }
      })
    else
      # Identify
      send_ws(state.ws_pid, %{
        op: 2,
        d: %{
          token: state.token,
          intents: 33_281,
          properties: %{
            os: "linux",
            browser: "nex_agent",
            device: "nex_agent"
          }
        }
      })
    end

    state
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "READY", "d" => data, "s" => seq}, state) do
    user_id = get_in(data, ["user", "id"])
    session_id = Map.get(data, "session_id")
    resume_url = Map.get(data, "resume_gateway_url")

    Logger.info("[Discord] Connected as #{get_in(data, ["user", "username"])} (#{user_id})")

    %{
      state
      | bot_user_id: user_id,
        session_id: session_id,
        resume_gateway_url: resume_url,
        sequence: seq
    }
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "MESSAGE_CREATE", "d" => data, "s" => seq}, state) do
    state = %{state | sequence: seq}
    handle_message(data, state)
    state
  end

  defp handle_gateway_event(%{"op" => 11}, state) do
    # Heartbeat ACK
    state
  end

  defp handle_gateway_event(%{"op" => 7}, state) do
    # Reconnect requested
    Logger.info("[Discord] Gateway requesting reconnect")
    Process.send_after(self(), :reconnect, 1_000)
    state
  end

  defp handle_gateway_event(%{"op" => 9, "d" => resumable}, state) do
    # Invalid session
    Logger.warning("[Discord] Invalid session (resumable=#{resumable})")
    state = if resumable, do: state, else: %{state | session_id: nil, sequence: nil}
    Process.send_after(self(), :reconnect, Enum.random(1_000..5_000))
    state
  end

  defp handle_gateway_event(%{"s" => seq}, state) when is_integer(seq) do
    %{state | sequence: seq}
  end

  defp handle_gateway_event(_payload, state), do: state

  defp handle_message(data, state) do
    author_id = get_in(data, ["author", "id"])
    channel_id = Map.get(data, "channel_id")
    content = Map.get(data, "content", "")
    guild_id = Map.get(data, "guild_id")

    # Ignore bot's own messages
    if author_id == state.bot_user_id do
      :ignore
    else
      # Check bot mention or DM
      is_dm = is_nil(guild_id)

      mentions_bot =
        data
        |> Map.get("mentions", [])
        |> Enum.any?(fn m -> Map.get(m, "id") == state.bot_user_id end)

      if is_dm or mentions_bot do
        # Strip bot mention from content
        clean_content =
          Regex.replace(~r/<@!?#{state.bot_user_id}>/, content, "")
          |> String.trim()

        if clean_content != "" and allowed?(channel_id, state.allow_from) do
          Logger.info("[Discord] Inbound from #{author_id} in #{channel_id}")

          Bus.publish(:inbound, %{
            channel: "discord",
            chat_id: to_string(channel_id),
            sender_id: to_string(author_id),
            content: clean_content,
            metadata: %{
              "guild_id" => guild_id,
              "message_id" => Map.get(data, "id"),
              "username" => get_in(data, ["author", "username"])
            }
          })
        end
      end
    end
  end

  # REST API

  defp do_send(%{chat_id: channel_id, content: content}, state) do
    url = "#{@discord_api}/channels/#{channel_id}/messages"

    # Discord has a 2000 char limit per message
    chunks = chunk_message(content, 2000)

    Enum.each(chunks, fn chunk ->
      case Req.post(url,
             json: %{content: chunk},
             headers: [{"authorization", "Bot #{state.token}"}],
             retry: false
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 429, body: body}} ->
          retry_after = get_in(body, ["retry_after"]) || 1
          Logger.warning("[Discord] Rate limited, retry after #{retry_after}s")
          Process.sleep(trunc(retry_after * 1000))
          do_send(%{chat_id: channel_id, content: chunk}, state)

        {:ok, resp} ->
          Logger.error("[Discord] Send failed: #{inspect(resp.status)} #{inspect(resp.body)}")

        {:error, reason} ->
          Logger.error("[Discord] Send error: #{inspect(reason)}")
      end
    end)
  end

  defp do_send(payload, _state) do
    Logger.error("[Discord] Invalid outbound payload: #{inspect(payload)}")
  end

  defp chunk_message(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      {chunk, rest} = String.split_at(text, max_len)
      [chunk | chunk_message(rest, max_len)]
    end
  end

  # WebSocket helpers

  defp connect_gateway(_state) do
    parent = self()

    if Code.ensure_loaded?(:websocket_client) and
         function_exported?(:websocket_client, :start_link, 4) do
      _pid =
        spawn_link(fn ->
          case :websocket_client.start_link(
                 String.to_charlist(@gateway_url),
                 __MODULE__.WsHandler,
                 [parent: parent],
                 []
               ) do
            {:ok, ws_pid} ->
              send(parent, {:ws_connected, ws_pid})
              ref = Process.monitor(ws_pid)
              send(parent, {:ws_monitor, ref})
              Process.sleep(:infinity)

            {:error, reason} ->
              send(parent, {:ws_error, reason})
          end
        end)

      {:ok, %{ws_pid: nil, ws_ref: nil}}
    else
      {:error, :websocket_unavailable}
    end

    # For now, use a simple WebSocket approach via Mint
    # The actual WebSocket implementation will use Mint.WebSocket
  rescue
    _ -> {:error, :websocket_unavailable}
  end

  defp send_ws(nil, _payload), do: :ok

  defp send_ws(ws_pid, payload) do
    send(ws_pid, {:send, Jason.encode!(payload)})
  rescue
    _ -> :ok
  end

  defp close_ws(%{ws_pid: nil} = state), do: state

  defp close_ws(%{ws_pid: pid} = state) do
    _ = Process.exit(pid, :shutdown)
    cancel_heartbeat(%{state | ws_pid: nil, ws_ref: nil})
  rescue
    _ -> cancel_heartbeat(%{state | ws_pid: nil, ws_ref: nil})
  end

  defp cancel_heartbeat(%{heartbeat_timer: nil} = state), do: state

  defp cancel_heartbeat(%{heartbeat_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | heartbeat_timer: nil}
  end

  defp allowed?(_channel_id, []), do: true

  defp allowed?(channel_id, allow_from) do
    to_string(channel_id) in allow_from
  end
end
