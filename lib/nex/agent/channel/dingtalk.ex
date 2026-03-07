defmodule Nex.Agent.Channel.DingTalk do
  @moduledoc """
  DingTalk channel using Stream Mode (long-lived HTTP connection).

  Connects to DingTalk via the Stream Mode API for receiving events, and uses
  the Robot API for sending messages. Follows the same Bus pub/sub pattern as other channels.

  ## Configuration

      %{
        "enabled" => true,
        "app_key" => "ding...",        # AppKey from DingTalk developer console
        "app_secret" => "...",          # AppSecret
        "robot_code" => "ding...",      # Robot code for outgoing messages
        "allow_from" => []              # Allowed conversation IDs (empty = all)
      }

  ## Requirements

  - Create a custom robot in DingTalk developer console
  - Enable Stream Mode for the robot
  - The robot needs message receiving permissions
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}

  @dingtalk_api "https://api.dingtalk.com"
  @stream_api "https://api.dingtalk.com/v1.0/gateway/connections/open"
  @reconnect_delay_ms 5_000
  @token_refresh_interval_ms 6_000_000

  defstruct [
    :app_key,
    :app_secret,
    :robot_code,
    :allow_from,
    :enabled,
    :access_token,
    :access_token_expires_at,
    :stream_url,
    :stream_ticket,
    :ws_pid,
    :ws_ref,
    :token_refresh_timer
  ]

  @type t :: %__MODULE__{
          app_key: String.t(),
          app_secret: String.t(),
          robot_code: String.t(),
          allow_from: [String.t()],
          enabled: boolean(),
          access_token: String.t() | nil,
          access_token_expires_at: integer() | nil,
          stream_url: String.t() | nil,
          stream_ticket: String.t() | nil,
          ws_pid: pid() | nil,
          ws_ref: reference() | nil,
          token_refresh_timer: reference() | nil
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), map()) :: :ok
  def send_message(conversation_id, content, metadata \\ %{}) do
    Bus.publish(:dingtalk_outbound, %{
      chat_id: to_string(conversation_id),
      content: content,
      metadata: metadata
    })
  end

  # Server

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)

    config = Keyword.get(opts, :config, Config.load())
    dingtalk = Config.dingtalk(config)

    state = %__MODULE__{
      app_key: Map.get(dingtalk, "app_key", ""),
      app_secret: Map.get(dingtalk, "app_secret", ""),
      robot_code: Map.get(dingtalk, "robot_code", ""),
      allow_from: Config.dingtalk_allow_from(config),
      enabled: Config.dingtalk_enabled?(config)
    }

    Bus.subscribe(:dingtalk_outbound)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_continue(:connect, %{app_key: ""} = state) do
    Logger.warning("[DingTalk] No app_key configured, disabling")
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case obtain_access_token(state) do
      {:ok, new_state} ->
        case open_stream(new_state) do
          {:ok, final_state} ->
            timer = Process.send_after(self(), :refresh_token, @token_refresh_interval_ms)
            {:noreply, %{final_state | token_refresh_timer: timer}}

          {:error, reason} ->
            Logger.error("[DingTalk] Stream open failed: #{inspect(reason)}")
            Process.send_after(self(), :reconnect, @reconnect_delay_ms)
            {:noreply, new_state}
        end

      {:error, reason} ->
        Logger.error("[DingTalk] Token fetch failed: #{inspect(reason)}")
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
  def handle_info(:refresh_token, state) do
    case obtain_access_token(state) do
      {:ok, new_state} ->
        timer = Process.send_after(self(), :refresh_token, @token_refresh_interval_ms)
        {:noreply, %{new_state | token_refresh_timer: timer}}

      {:error, reason} ->
        Logger.warning("[DingTalk] Token refresh failed: #{inspect(reason)}")
        timer = Process.send_after(self(), :refresh_token, 60_000)
        {:noreply, %{state | token_refresh_timer: timer}}
    end
  end

  @impl true
  def handle_info({:ws_message, frame}, state) do
    case Jason.decode(frame) do
      {:ok, payload} ->
        state = handle_stream_event(payload, state)
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ws_closed, _reason}, state) do
    Logger.warning("[DingTalk] Stream closed, reconnecting...")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil}}
  end

  @impl true
  def handle_info({:bus_message, :dingtalk_outbound, payload}, state) when is_map(payload) do
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    Logger.warning("[DingTalk] WS process down: #{inspect(reason)}")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil, ws_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Stream events

  defp handle_stream_event(
         %{"headers" => headers, "data" => data_str} = _event,
         state
       ) do
    topic = Map.get(headers, "topic", "")

    case Jason.decode(data_str || "{}") do
      {:ok, data} ->
        if topic == "/v1.0/im/bot/messages/get" do
          handle_bot_message(data, state)
        end

      {:error, _} ->
        :ok
    end

    state
  end

  defp handle_stream_event(_payload, state), do: state

  defp handle_bot_message(data, state) do
    text = get_in(data, ["text", "content"]) || ""
    sender_id = get_in(data, ["senderStaffId"]) || get_in(data, ["senderId"]) || ""
    conversation_id = Map.get(data, "conversationId", "")
    conversation_type = Map.get(data, "conversationType", "")
    msg_id = Map.get(data, "msgId", "")

    # In group chats, the bot is @mentioned; strip the mention
    clean_text = String.trim(text)

    if clean_text != "" and allowed?(conversation_id, state.allow_from) do
      Logger.info("[DingTalk] Inbound from #{sender_id} in #{conversation_id}")

      Bus.publish(:inbound, %{
        channel: "dingtalk",
        chat_id: to_string(conversation_id),
        sender_id: to_string(sender_id),
        content: clean_text,
        metadata: %{
          "conversation_type" => conversation_type,
          "msg_id" => msg_id,
          "webhook_url" => Map.get(data, "sessionWebhook"),
          "sender_nick" => Map.get(data, "senderNick")
        }
      })
    end
  end

  # REST API

  defp do_send(%{chat_id: _conversation_id, content: content} = payload, state) do
    metadata = Map.get(payload, :metadata, %{})

    # Prefer session webhook for replying (works for both 1:1 and group chats)
    case Map.get(metadata, "webhook_url") do
      url when is_binary(url) and url != "" ->
        send_via_webhook(url, content)

      _ ->
        send_via_api(payload, content, state)
    end
  end

  defp do_send(payload, _state) do
    Logger.error("[DingTalk] Invalid outbound payload: #{inspect(payload)}")
  end

  defp send_via_webhook(url, content) do
    body = %{
      msgtype: "text",
      text: %{content: content}
    }

    case Req.post(url, json: body, retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, resp} ->
        Logger.error("[DingTalk] Webhook send failed: #{inspect(resp.status)}")

      {:error, reason} ->
        Logger.error("[DingTalk] Webhook error: #{inspect(reason)}")
    end
  end

  defp send_via_api(%{chat_id: conversation_id} = _payload, content, state) do
    url = "#{@dingtalk_api}/v1.0/robot/oToMessages/batchSend"

    body = %{
      robotCode: state.robot_code,
      userIds: [conversation_id],
      msgKey: "sampleText",
      msgParam: Jason.encode!(%{content: content})
    }

    case Req.post(url,
           json: body,
           headers: [
             {"x-acs-dingtalk-access-token", state.access_token || ""},
             {"content-type", "application/json"}
           ],
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, resp} ->
        Logger.error("[DingTalk] API send failed: #{inspect(resp.status)} #{inspect(resp.body)}")

      {:error, reason} ->
        Logger.error("[DingTalk] API error: #{inspect(reason)}")
    end
  end

  # Token management

  defp obtain_access_token(state) do
    url = "#{@dingtalk_api}/v1.0/oauth2/accessToken"

    body = %{
      appKey: state.app_key,
      appSecret: state.app_secret
    }

    case Req.post(url, json: body, retry: false) do
      {:ok, %{body: %{"accessToken" => token, "expireIn" => expires_in}}} ->
        expires_at = System.system_time(:second) + expires_in
        Logger.info("[DingTalk] Access token obtained, expires in #{expires_in}s")
        {:ok, %{state | access_token: token, access_token_expires_at: expires_at}}

      {:ok, %{body: body}} ->
        {:error, "Unexpected response: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_stream(state) do
    body = %{
      clientId: state.app_key,
      clientSecret: state.app_secret,
      subscriptions: [
        %{type: "EVENT", topic: "/v1.0/im/bot/messages/get"}
      ],
      ua: "nex_agent/1.0"
    }

    case Req.post(@stream_api, json: body, retry: false) do
      {:ok, %{body: %{"endpoint" => endpoint, "ticket" => ticket}}} ->
        Logger.info("[DingTalk] Stream endpoint: #{endpoint}")
        {:ok, %{state | stream_url: endpoint, stream_ticket: ticket}}

      {:ok, %{body: body}} ->
        {:error, "Stream open failed: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # WebSocket helpers

  defp close_ws(%{ws_pid: nil} = state), do: state

  defp close_ws(%{ws_pid: pid} = state) do
    try do
      Process.exit(pid, :shutdown)
    rescue
      _ -> :ok
    end

    %{state | ws_pid: nil, ws_ref: nil}
  end

  defp allowed?(_conversation_id, []), do: true

  defp allowed?(conversation_id, allow_from) do
    to_string(conversation_id) in allow_from
  end
end
