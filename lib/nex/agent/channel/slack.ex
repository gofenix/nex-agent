defmodule Nex.Agent.Channel.Slack do
  @moduledoc """
  Slack channel using Socket Mode (WebSocket).

  Connects to Slack via Socket Mode API for receiving events, and uses
  Web API for sending messages. Follows the same Bus pub/sub pattern as other channels.

  ## Configuration

      %{
        "enabled" => true,
        "app_token" => "xapp-...",      # App-level token (for Socket Mode)
        "bot_token" => "xoxb-...",      # Bot token (for Web API)
        "allow_from" => ["channel_id"], # Allowed channel IDs (empty = all)
      }

  ## Requirements

  - Socket Mode must be enabled in the Slack app settings
  - App-level token must have `connections:write` scope
  - Bot token needs: `chat:write`, `app_mentions:read`, `im:history`, `im:read`
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}

  @slack_api "https://slack.com/api"
  @reconnect_delay_ms 5_000
  @ping_interval_ms 30_000

  defstruct [
    :app_token,
    :bot_token,
    :allow_from,
    :enabled,
    :ws_url,
    :ws_pid,
    :ws_ref,
    :ping_timer,
    :bot_user_id
  ]

  @type t :: %__MODULE__{
          app_token: String.t(),
          bot_token: String.t(),
          allow_from: [String.t()],
          enabled: boolean(),
          ws_url: String.t() | nil,
          ws_pid: pid() | nil,
          ws_ref: reference() | nil,
          ping_timer: reference() | nil,
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
    Bus.publish(:slack_outbound, %{
      chat_id: to_string(channel_id),
      content: content,
      metadata: metadata
    })
  end

  # Server

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)

    config = Keyword.get(opts, :config, Config.load())
    slack = Config.slack(config)

    state = %__MODULE__{
      app_token: Map.get(slack, "app_token", ""),
      bot_token: Map.get(slack, "bot_token", ""),
      allow_from: Config.slack_allow_from(config),
      enabled: Config.slack_enabled?(config)
    }

    Bus.subscribe(:slack_outbound)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_continue(:connect, %{app_token: ""} = state) do
    Logger.warning("[Slack] No app_token configured, disabling")
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:connect, %{bot_token: ""} = state) do
    Logger.warning("[Slack] No bot_token configured, disabling")
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:connect, state) do
    # Get bot user ID
    state = fetch_bot_identity(state)

    # Open Socket Mode connection
    case open_socket_mode(state) do
      {:ok, ws_url} ->
        Logger.info("[Slack] Socket Mode URL obtained")
        {:noreply, %{state | ws_url: ws_url}}

      {:error, reason} ->
        Logger.error("[Slack] Failed to open Socket Mode: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = close_ws(state)
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:ping, %{ws_pid: nil} = state), do: {:noreply, state}

  @impl true
  def handle_info(:ping, state) do
    # Send ping via WebSocket
    send_ws(state.ws_pid, %{type: "ping"})
    timer = Process.send_after(self(), :ping, @ping_interval_ms)
    {:noreply, %{state | ping_timer: timer}}
  end

  @impl true
  def handle_info({:ws_message, frame}, state) do
    case Jason.decode(frame) do
      {:ok, payload} ->
        state = handle_socket_event(payload, state)
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ws_closed, _reason}, state) do
    Logger.warning("[Slack] WebSocket closed, reconnecting...")
    state = cancel_ping(state)
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil}}
  end

  @impl true
  def handle_info({:bus_message, :slack_outbound, payload}, state) when is_map(payload) do
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    Logger.warning("[Slack] WS process down: #{inspect(reason)}")
    state = cancel_ping(state)
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil, ws_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Socket Mode events

  defp handle_socket_event(%{"type" => "hello"}, state) do
    Logger.info("[Slack] Socket Mode connected")
    timer = Process.send_after(self(), :ping, @ping_interval_ms)
    %{state | ping_timer: timer}
  end

  defp handle_socket_event(%{"type" => "disconnect", "reason" => reason}, state) do
    Logger.info("[Slack] Disconnect requested: #{reason}")
    Process.send_after(self(), :reconnect, 1_000)
    state
  end

  defp handle_socket_event(
         %{"type" => "events_api", "envelope_id" => envelope_id, "payload" => payload},
         state
       ) do
    # Acknowledge the event
    send_ws(state.ws_pid, %{envelope_id: envelope_id})

    # Process the event
    handle_slack_event(payload, state)
    state
  end

  defp handle_socket_event(_payload, state), do: state

  defp handle_slack_event(%{"event" => %{"type" => "message"} = event}, state) do
    # Ignore bot messages, message_changed, etc.
    subtype = Map.get(event, "subtype")
    user = Map.get(event, "user")
    channel = Map.get(event, "channel")
    text = Map.get(event, "text", "")

    cond do
      subtype != nil ->
        :ignore

      user == state.bot_user_id ->
        :ignore

      text == "" ->
        :ignore

      not allowed?(channel, state.allow_from) ->
        Logger.debug("[Slack] Message from non-allowed channel #{channel}")

      true ->
        # Strip bot mention
        clean_text =
          Regex.replace(~r/<@#{state.bot_user_id}>/, text, "")
          |> String.trim()

        if clean_text != "" do
          Logger.info("[Slack] Inbound from #{user} in #{channel}")

          Bus.publish(:inbound, %{
            channel: "slack",
            chat_id: to_string(channel),
            sender_id: to_string(user),
            content: clean_text,
            metadata: %{
              "ts" => Map.get(event, "ts"),
              "thread_ts" => Map.get(event, "thread_ts")
            }
          })
        end
    end
  end

  defp handle_slack_event(%{"event" => %{"type" => "app_mention"} = event}, state) do
    user = Map.get(event, "user")
    channel = Map.get(event, "channel")
    text = Map.get(event, "text", "")

    if user != state.bot_user_id and allowed?(channel, state.allow_from) do
      clean_text =
        Regex.replace(~r/<@#{state.bot_user_id}>/, text, "")
        |> String.trim()

      if clean_text != "" do
        Logger.info("[Slack] Mention from #{user} in #{channel}")

        Bus.publish(:inbound, %{
          channel: "slack",
          chat_id: to_string(channel),
          sender_id: to_string(user),
          content: clean_text,
          metadata: %{
            "ts" => Map.get(event, "ts"),
            "thread_ts" => Map.get(event, "thread_ts")
          }
        })
      end
    end
  end

  defp handle_slack_event(_payload, _state), do: :ok

  # REST API

  defp do_send(%{chat_id: channel_id, content: content} = payload, state) do
    metadata = Map.get(payload, :metadata, %{})
    thread_ts = Map.get(metadata, "thread_ts")

    body =
      %{channel: channel_id, text: content}
      |> then(fn b -> if thread_ts, do: Map.put(b, :thread_ts, thread_ts), else: b end)

    case Req.post("#{@slack_api}/chat.postMessage",
           json: body,
           headers: [{"authorization", "Bearer #{state.bot_token}"}],
           retry: false
         ) do
      {:ok, %{body: %{"ok" => true}}} ->
        :ok

      {:ok, %{body: %{"ok" => false, "error" => error}}} ->
        Logger.error("[Slack] Send failed: #{error}")

      {:error, reason} ->
        Logger.error("[Slack] Send error: #{inspect(reason)}")
    end
  end

  defp do_send(payload, _state) do
    Logger.error("[Slack] Invalid outbound payload: #{inspect(payload)}")
  end

  # Helpers

  defp fetch_bot_identity(state) do
    case Req.post("#{@slack_api}/auth.test",
           headers: [{"authorization", "Bearer #{state.bot_token}"}],
           retry: false
         ) do
      {:ok, %{body: %{"ok" => true, "user_id" => user_id}}} ->
        Logger.info("[Slack] Bot identity: #{user_id}")
        %{state | bot_user_id: user_id}

      _ ->
        Logger.warning("[Slack] Failed to fetch bot identity")
        state
    end
  end

  defp open_socket_mode(state) do
    case Req.post("#{@slack_api}/apps.connections.open",
           headers: [{"authorization", "Bearer #{state.app_token}"}],
           retry: false
         ) do
      {:ok, %{body: %{"ok" => true, "url" => url}}} ->
        {:ok, url}

      {:ok, %{body: %{"ok" => false, "error" => error}}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
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
    cancel_ping(%{state | ws_pid: nil, ws_ref: nil})
  rescue
    _ -> cancel_ping(%{state | ws_pid: nil, ws_ref: nil})
  end

  defp cancel_ping(%{ping_timer: nil} = state), do: state

  defp cancel_ping(%{ping_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | ping_timer: nil}
  end

  defp allowed?(_channel_id, []), do: true

  defp allowed?(channel_id, allow_from) do
    to_string(channel_id) in allow_from
  end
end
