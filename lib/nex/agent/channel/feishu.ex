defmodule Nex.Agent.Channel.Feishu do
  @moduledoc """
  Feishu channel (v2):
  - WebSocket long connection for inbound events
  - Message deduplication (based on message_id)
  - Bot message filtering
  - react_emoji automatic response
  - Support for text, post, image, file, audio, media types
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Feishu.{Frame, WSClient}

  @feishu_api "https://open.feishu.cn/open-apis"
  @feishu_ws_endpoint "https://open.feishu.cn/callback/ws/endpoint"
  @default_send_timeout_ms 15_000
  @dedup_cache_max 1000

  defstruct [
    :app_id,
    :app_secret,
    :encrypt_key,
    :verification_token,
    :allow_from,
    :react_emoji,
    :enabled,
    :http_post_fun,
    :http_post_multipart_fun,
    :http_get_fun,
    :tenant_access_token,
    :tenant_access_token_expire_at,
    :ws_pid,
    :ws_monitor_ref,
    :ws_reconnect_timer,
    :ws_ping_interval,
    :ws_ping_timer,
    :ws_service_id,
    ws_pending_fragments: %{},
    processed_message_ids: []
  ]

  @type t :: %__MODULE__{
          app_id: String.t(),
          app_secret: String.t(),
          encrypt_key: String.t() | nil,
          verification_token: String.t() | nil,
          allow_from: [String.t()],
          react_emoji: String.t(),
          enabled: boolean(),
          http_post_fun: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()}),
          http_post_multipart_fun: (String.t(), keyword(), keyword() ->
                                      {:ok, map()} | {:error, term()}),
          http_get_fun: (String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          tenant_access_token: String.t() | nil,
          tenant_access_token_expire_at: integer() | nil,
          ws_pid: pid() | nil,
          ws_monitor_ref: reference() | nil,
          ws_reconnect_timer: reference() | nil,
          ws_ping_interval: integer() | nil,
          ws_ping_timer: reference() | nil,
          ws_service_id: integer() | nil,
          ws_pending_fragments: map(),
          processed_message_ids: [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), map()) :: :ok
  def send_message(chat_id, content, metadata \\ %{}) do
    Bus.publish(:feishu_outbound, %{
      chat_id: to_string(chat_id),
      content: content,
      metadata: metadata
    })
  end

  @doc "Send a message synchronously and confirm whether Feishu accepted it."
  @spec deliver_message(String.t(), String.t() | nil, map()) :: :ok | {:error, term()}
  def deliver_message(chat_id, content, metadata \\ %{}) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:send_message, chat_id, content, metadata}, 15_000)
    else
      {:error, :feishu_not_running}
    end
  end

  @doc "Upload a local image and send it as a native Feishu image message."
  @spec deliver_local_image(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def deliver_local_image(chat_id, image_path, metadata \\ %{}) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:send_local_image, chat_id, image_path, metadata}, 30_000)
    else
      {:error, :feishu_not_running}
    end
  end

  @doc "Send an interactive card and return its message_id for subsequent PATCH updates."
  @spec send_card(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def send_card(chat_id, content, metadata \\ %{}) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:send_card, chat_id, content, metadata}, 15_000)
    else
      {:error, :feishu_not_running}
    end
  end

  @doc "Update an existing card message via PATCH."
  @spec update_card(String.t(), String.t()) :: :ok | {:error, term()}
  def update_card(message_id, content) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:update_card, message_id, content})
    else
      {:error, :feishu_not_running}
    end
  end

  @spec ingest_event(map()) :: :ok | {:ok, map()} | {:error, term()}
  def ingest_event(payload) when is_map(payload) do
    GenServer.call(__MODULE__, {:ingest_event, payload})
  end

  @spec start_websocket() :: :ok | {:error, term()}
  def start_websocket do
    GenServer.call(__MODULE__, :start_websocket)
  end

  @spec stop_websocket() :: :ok
  def stop_websocket do
    GenServer.call(__MODULE__, :stop_websocket)
  end

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)

    config = Keyword.get(opts, :config, Config.load())
    feishu = Config.feishu(config)

    state = %__MODULE__{
      app_id: Map.get(feishu, "app_id", ""),
      app_secret: Map.get(feishu, "app_secret", ""),
      encrypt_key: Config.feishu_encrypt_key(config),
      verification_token: Config.feishu_verification_token(config),
      allow_from: Config.feishu_allow_from(config),
      react_emoji: Config.feishu_react_emoji(config),
      enabled: Config.feishu_enabled?(config),
      http_post_fun: Keyword.get(opts, :http_post_fun, &default_http_post/3),
      http_post_multipart_fun:
        Keyword.get(opts, :http_post_multipart_fun, &default_http_post_multipart/3),
      http_get_fun: Keyword.get(opts, :http_get_fun, &default_http_get/2),
      tenant_access_token: nil,
      tenant_access_token_expire_at: nil,
      ws_pid: nil,
      ws_monitor_ref: nil,
      ws_reconnect_timer: nil,
      ws_ping_interval: nil,
      ws_ping_timer: nil,
      ws_service_id: nil,
      ws_pending_fragments: %{},
      processed_message_ids: []
    }

    Bus.subscribe(:feishu_outbound)

    state =
      if state.enabled do
        maybe_start_websocket(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:start_websocket, _from, state) do
    if state.ws_pid do
      {:reply, {:error, :already_running}, state}
    else
      case start_ws_connection(state) do
        {:ok, new_state} -> {:reply, :ok, new_state}
        {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
      end
    end
  end

  @impl true
  def handle_call(:stop_websocket, _from, state) do
    {:reply, :ok, stop_ws(state)}
  end

  @impl true
  def handle_call(:get_tenant_access_token, _from, state) do
    case get_tenant_access_token(state) do
      {:ok, token, new_state} ->
        {:reply, {:ok, token}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_message, chat_id, content, metadata}, _from, state) do
    payload = %{
      chat_id: to_string(chat_id),
      content: content,
      metadata: metadata
    }

    case do_send(payload, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:send_local_image, chat_id, image_path, metadata}, _from, state) do
    case do_send_local_image(chat_id, image_path, metadata, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:send_card, chat_id, content, metadata}, _from, state) do
    case do_send_card_with_id(chat_id, content, metadata, state) do
      {:ok, message_id, new_state} ->
        {:reply, {:ok, message_id}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:ingest_event, payload}, _from, state) do
    case normalize_event(payload) do
      {:challenge, challenge} ->
        {:reply, {:ok, %{"challenge" => challenge}}, state}

      {:ok, inbound} ->
        {:reply, :ok, process_inbound_message(inbound, state)}

      :ignore ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:bus_message, :feishu_outbound, payload}, state) when is_map(payload) do
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    update_mid = Map.get(metadata, "_update_message_id") || Map.get(metadata, :_update_message_id)

    if is_binary(update_mid) and update_mid != "" do
      content = Map.get(payload, :content) || Map.get(payload, "content") || ""

      case do_patch_card(update_mid, content, state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason, _new_state} ->
          Logger.warning(
            "[Feishu] Card PATCH failed (#{update_mid}): #{inspect(reason)}, falling back to new message"
          )

          case do_send(payload, state) do
            {:ok, s} -> {:noreply, s}
            {:error, _, s} -> {:noreply, s}
          end
      end
    else
      case do_send(payload, state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason, new_state} ->
          Logger.warning("Feishu send failed: #{inspect(reason)}")
          {:noreply, new_state}
      end
    end
  end

  @impl true
  def handle_info({:feishu_ws_event, pid, raw_frame, event_json}, %{ws_pid: pid} = state) do
    {state, maybe_event} = merge_ws_fragment(raw_frame, event_json, state)

    state =
      case maybe_event do
        nil ->
          state

        full_json when is_binary(full_json) ->
          _ = send_ws_ack(raw_frame, state)

          case Jason.decode(full_json) do
            {:ok, payload} -> handle_ws_event_payload(payload, state)
            _ -> state
          end
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:feishu_ws_disconnected, pid, reason}, %{ws_pid: pid} = state) do
    Logger.warning("Feishu WebSocket disconnected: #{inspect(reason)}")
    {:noreply, schedule_ws_reconnect(clear_ws_state(state))}
  end

  @impl true
  def handle_info(:reconnect_ws, state) do
    state = %{state | ws_reconnect_timer: nil}
    {:noreply, maybe_start_websocket(state)}
  end

  @impl true
  def handle_info(:feishu_ws_send_initial_ping, %{ws_pid: ws_pid, ws_service_id: svc_id} = state)
      when is_pid(ws_pid) do
    ping = %Frame{
      seq_id: 0,
      log_id: 0,
      service: svc_id || 0,
      method: Frame.method_control(),
      headers: [{"type", "ping"}],
      payload: <<>>
    }

    _ = WSClient.send_frame(ws_pid, ping)
    Logger.info("[Feishu] Sent initial ping service_id=#{svc_id || 0}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:feishu_ws_send_initial_ping, state), do: {:noreply, state}

  @impl true
  def handle_info(:ws_ping, %{ws_pid: ws_pid, ws_service_id: svc_id} = state)
      when is_pid(ws_pid) do
    ping = %Frame{
      seq_id: 0,
      log_id: 0,
      service: svc_id || 0,
      method: Frame.method_control(),
      headers: [{"type", "ping"}],
      payload: <<>>
    }

    _ = WSClient.send_frame(ws_pid, ping)
    {:noreply, schedule_ws_ping(state)}
  end

  @impl true
  def handle_info(:ws_ping, state), do: {:noreply, state}

  @impl true
  def handle_info({:feishu_ws_pong_config, ping_interval_s}, state)
      when is_integer(ping_interval_s) and ping_interval_s > 0 do
    new_interval = ping_interval_s * 1000
    state = %{state | ws_ping_interval: new_interval}
    {:noreply, schedule_ws_ping(state)}
  end

  @impl true
  def handle_info({:feishu_ws_pong_config, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when pid == state.ws_pid do
    Logger.warning("Feishu WebSocket disconnected: #{inspect(reason)}")
    {:noreply, schedule_ws_reconnect(clear_ws_state(state))}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:update_card, message_id, content}, state) do
    case do_patch_card(message_id, content, state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason, new_state} ->
        Logger.warning("[Feishu] Card update cast failed: #{inspect(reason)}")
        {:noreply, new_state}
    end
  end

  defp add_reaction(_message_id, %{react_emoji: ""}), do: :ok
  defp add_reaction(_, %{enabled: false}), do: :ok

  defp add_reaction(message_id, state) when is_binary(message_id) and message_id != "" do
    Task.start(fn ->
      with {:ok, token, _} <- get_tenant_access_token(state),
           {:ok, _} <-
             feishu_post(
               state,
               "/im/v1/messages/#{message_id}/reactions",
               %{"reaction_type" => %{"emoji_type" => state.react_emoji}},
               [{"Authorization", "Bearer #{token}"}]
             ) do
        Logger.debug("Added #{state.react_emoji} reaction to #{message_id}")
      else
        {:error, reason} ->
          Logger.warning("Failed to add reaction: #{inspect(reason)}")
      end
    end)
  end

  defp add_reaction(_, _), do: :ok

  defp maybe_start_websocket(%{ws_pid: nil, enabled: true} = state) do
    case start_ws_connection(state) do
      {:ok, new_state} ->
        new_state

      {:error, reason, new_state} ->
        Logger.warning("Failed to start Feishu WebSocket: #{inspect(reason)}")
        schedule_ws_reconnect(new_state)
    end
  end

  defp maybe_start_websocket(state), do: state

  defp start_ws_connection(%{app_id: app_id, app_secret: app_secret} = state)
       when app_id in [nil, ""] or app_secret in [nil, ""] do
    {:error, :missing_credentials, state}
  end

  defp start_ws_connection(state) do
    with {:ok, ws_url, ping_interval, service_id} <- fetch_ws_endpoint(state),
         {:ok, pid} <- WSClient.start_link(ws_url, [], self()) do
      ref = Process.monitor(pid)

      state = %{
        state
        | ws_pid: pid,
          ws_monitor_ref: ref,
          ws_ping_interval: ping_interval,
          ws_service_id: service_id
      }

      {:ok, schedule_ws_ping(state)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch_ws_endpoint(state) do
    result =
      state.http_post_fun.(
        @feishu_ws_endpoint,
        %{"AppID" => state.app_id, "AppSecret" => state.app_secret},
        [{"locale", "zh"}]
      )

    case result do
      {:ok, %{body: %{"code" => 0, "data" => %{"URL" => url} = data}}} ->
        extract_endpoint_ok(url, data)

      {:ok, %{"code" => 0, "data" => %{"URL" => url} = data}} ->
        extract_endpoint_ok(url, data)

      {:ok, %{body: body}} ->
        Logger.warning("[Feishu] WS endpoint error: #{inspect(body)}")
        {:error, {:ws_endpoint_error, body}}

      {:ok, body} when is_map(body) ->
        Logger.warning("[Feishu] WS endpoint error: #{inspect(body)}")
        {:error, {:ws_endpoint_error, body}}

      {:error, reason} ->
        Logger.warning("[Feishu] WS endpoint request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_endpoint_ok(url, data) do
    ping_ms = get_in(data, ["ClientConfig", "PingInterval"])
    ping_ms = if is_integer(ping_ms) and ping_ms > 0, do: ping_ms * 1000, else: 120_000
    service_id = extract_service_id(url)
    Logger.info("[Feishu] Got WS endpoint service_id=#{service_id} ping=#{ping_ms}ms")
    {:ok, url, ping_ms, service_id}
  end

  defp extract_service_id(url) do
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    case Integer.parse(Map.get(params, "service_id", "0")) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp merge_ws_fragment(raw_frame, event_json, state) do
    headers = Map.new(raw_frame.headers)
    message_id = Map.get(headers, "message_id", "")
    sum = Map.get(headers, "sum", "1") |> parse_int(1)
    seq = Map.get(headers, "seq", "0") |> parse_int(0)

    if sum <= 1 do
      {state, event_json}
    else
      fragments = Map.get(state.ws_pending_fragments, message_id, %{})
      fragments = Map.put(fragments, seq, event_json)

      if map_size(fragments) >= sum do
        merged =
          0..(sum - 1)
          |> Enum.map_join(&Map.get(fragments, &1, <<>>))

        state = %{
          state
          | ws_pending_fragments: Map.delete(state.ws_pending_fragments, message_id)
        }

        {state, merged}
      else
        state = %{
          state
          | ws_pending_fragments: Map.put(state.ws_pending_fragments, message_id, fragments)
        }

        {state, nil}
      end
    end
  end

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  defp parse_int(n, _) when is_integer(n), do: n
  defp parse_int(_, default), do: default

  defp send_ws_ack(raw_frame, %{ws_pid: ws_pid}) when is_pid(ws_pid) do
    ack_payload = Jason.encode!(%{"code" => 200})

    ack_frame = %Frame{
      seq_id: raw_frame.seq_id,
      log_id: raw_frame.log_id,
      service: raw_frame.service,
      method: raw_frame.method,
      headers: raw_frame.headers ++ [{"biz_rt", "0"}],
      payload: ack_payload
    }

    WSClient.send_frame(ws_pid, ack_frame)
  end

  defp send_ws_ack(_, _), do: :ok

  defp handle_ws_event_payload(payload, state) do
    Logger.info("[Feishu] WS event payload=#{inspect(payload, limit: 500, printable_limit: 500)}")

    case normalize_event(payload) do
      {:ok, inbound} ->
        Logger.info(
          "[Feishu] Inbound sender=#{inbound[:sender_id]} chat=#{inbound[:chat_id]} content=#{inspect(inbound[:content])}"
        )

        process_inbound_message(inbound, state)

      :ignore ->
        Logger.debug("[Feishu] Event ignored keys=#{inspect(Map.keys(payload))}")
        state

      {:challenge, _} ->
        state
    end
  end

  defp schedule_ws_ping(%{ws_ping_interval: nil} = state), do: state

  defp schedule_ws_ping(%{ws_ping_interval: interval} = state) when is_integer(interval) do
    if state.ws_ping_timer, do: Process.cancel_timer(state.ws_ping_timer)
    timer = Process.send_after(self(), :ws_ping, interval)
    %{state | ws_ping_timer: timer}
  end

  defp stop_ws(state) do
    if state.ws_monitor_ref, do: Process.demonitor(state.ws_monitor_ref, [:flush])
    if state.ws_reconnect_timer, do: Process.cancel_timer(state.ws_reconnect_timer)
    if state.ws_ping_timer, do: Process.cancel_timer(state.ws_ping_timer)
    if state.ws_pid, do: Process.exit(state.ws_pid, :normal)

    %{state | ws_pid: nil, ws_monitor_ref: nil, ws_reconnect_timer: nil, ws_ping_timer: nil}
  end

  defp clear_ws_state(state) do
    if state.ws_monitor_ref, do: Process.demonitor(state.ws_monitor_ref, [:flush])
    if state.ws_ping_timer, do: Process.cancel_timer(state.ws_ping_timer)
    %{state | ws_pid: nil, ws_monitor_ref: nil, ws_ping_timer: nil}
  end

  defp schedule_ws_reconnect(%{enabled: false} = state), do: state

  defp schedule_ws_reconnect(%{ws_reconnect_timer: nil} = state) do
    timer = Process.send_after(self(), :reconnect_ws, 5_000)
    %{state | ws_reconnect_timer: timer}
  end

  defp schedule_ws_reconnect(state), do: state

  defp process_inbound_message(inbound, state) do
    message_id = Map.get(inbound, :message_id)

    if message_id && message_id in state.processed_message_ids do
      Logger.debug("Feishu duplicate message: #{message_id}")
      state
    else
      new_state =
        if message_id do
          %{
            state
            | processed_message_ids: trim_dedup_cache([message_id | state.processed_message_ids])
          }
        else
          state
        end

      if allowed?(Map.get(inbound, :sender_id), state.allow_from) do
        add_reaction(message_id, state)
        {inbound, new_state} = maybe_attach_inbound_media(inbound, new_state)

        Logger.info(
          "[Feishu] Publishing inbound to bus content=#{inspect(Map.get(inbound, :content))}"
        )

        Bus.publish(:inbound, inbound)
        new_state
      else
        Logger.warning(
          "Feishu inbound denied sender=#{Map.get(inbound, :sender_id)} allow_from=#{inspect(state.allow_from)}"
        )

        new_state
      end
    end
  end

  defp normalize_event(%{"type" => "url_verification", "challenge" => challenge})
       when is_binary(challenge) do
    {:challenge, challenge}
  end

  defp normalize_event(payload) when is_map(payload) do
    event = Map.get(payload, "event") || Map.get(payload, :event)
    message = event && (Map.get(event, "message") || Map.get(event, :message))
    sender = event && (Map.get(event, "sender") || Map.get(event, :sender))

    Logger.debug(
      "[Feishu] normalize_event keys=#{inspect(Map.keys(payload))} event_nil=#{is_nil(event)} message_nil=#{is_nil(message)} sender_nil=#{is_nil(sender)}"
    )

    if is_map(event) and is_map(message) and is_map(sender) do
      normalize_message(message, sender, payload)
    else
      Logger.debug(
        "[Feishu] normalize_event -> :ignore (event/message/sender missing) event=#{inspect(event)}"
      )

      :ignore
    end
  end

  defp normalize_message(message, sender, raw_payload) do
    msg_type = Map.get(message, "message_type") || Map.get(message, :message_type)
    chat_id = Map.get(message, "chat_id") || Map.get(message, :chat_id)
    chat_type = Map.get(message, "chat_type") || Map.get(message, :chat_type)
    message_id = Map.get(message, "message_id") || Map.get(message, :message_id)
    sender_id = extract_sender_open_id(sender)
    sender_type = Map.get(sender, "sender_type") || Map.get(sender, :sender_type)
    user_id = sender_id

    content_json =
      message
      |> Map.get("content", Map.get(message, :content))
      |> parse_content()

    normalized_content = normalize_inbound_content(msg_type, content_json, message_id)
    content = Map.get(normalized_content, "summary")
    resources = Map.get(normalized_content, "resources", [])

    Logger.debug(
      "[Feishu] normalize_message msg_type=#{inspect(msg_type)} sender_type=#{inspect(sender_type)} sender_id=#{inspect(sender_id)} chat_id=#{inspect(chat_id)} content=#{inspect(content)}"
    )

    cond do
      sender_type == "bot" ->
        Logger.debug("[Feishu] ignored: sender_type=bot")
        :ignore

      is_nil(sender_id) or sender_id == "" ->
        Logger.debug("[Feishu] ignored: sender_id nil/empty, sender=#{inspect(sender)}")
        :ignore

      is_nil(chat_id) or to_string(chat_id) == "" ->
        Logger.debug("[Feishu] ignored: chat_id nil/empty")
        :ignore

      is_nil(content) or content == "" ->
        Logger.debug(
          "[Feishu] ignored: content nil/empty, msg_type=#{inspect(msg_type)} content_json=#{inspect(content_json)}"
        )

        :ignore

      true ->
        reply_target = if to_string(chat_type) == "group", do: to_string(chat_id), else: sender_id

        {:ok,
         %{
           channel: "feishu",
           chat_id: reply_target,
           sender_id: sender_id,
           user_id: user_id,
           message_id: message_id,
           content: content,
           raw: raw_payload,
           metadata: %{
             "message_id" => message_id,
             "user_id" => user_id,
             "chat_type" => to_string(chat_type),
             "message_type" => msg_type,
             "raw_content_json" => content_json,
             "normalized_content" => Map.delete(normalized_content, "summary"),
             "resources" => resources
           }
         }}
    end
  end

  defp parse_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp parse_content(content) when is_map(content), do: content
  defp parse_content(_), do: %{}

  defp normalize_inbound_content("text", content_json, _message_id) do
    text = Map.get(content_json, "text") || Map.get(content_json, :text)
    %{"summary" => text, "text" => text, "resources" => []}
  end

  defp normalize_inbound_content("post", content_json, message_id) do
    {summary, resources} = extract_post_text(content_json, message_id)
    %{"summary" => summary, "post" => content_json, "resources" => resources}
  end

  defp normalize_inbound_content("image", content_json, message_id) do
    image_key =
      Map.get(content_json, "image_key") ||
        Map.get(content_json, :image_key)

    if image_key do
      %{
        "summary" => "[image: #{image_key} message_id:#{message_id}]",
        "image_key" => image_key,
        "resources" => [
          %{"type" => "image", "image_key" => image_key, "message_id" => message_id}
        ]
      }
    else
      %{"summary" => nil, "resources" => []}
    end
  end

  defp normalize_inbound_content(msg_type, content_json, _message_id)
       when msg_type in ["audio", "file", "media", "sticker", "folder"] do
    file_key =
      Map.get(content_json, "image_key") ||
        Map.get(content_json, "file_key") ||
        Map.get(content_json, :image_key) ||
        Map.get(content_json, :file_key)

    file_name = Map.get(content_json, "file_name") || Map.get(content_json, :file_name)
    duration = Map.get(content_json, "duration") || Map.get(content_json, :duration)

    if file_key do
      content_text =
        case file_name do
          name when is_binary(name) and name != "" -> "[#{msg_type}: #{name} #{file_key}]"
          _ -> "[#{msg_type}: #{file_key}]"
        end

      %{
        "summary" => content_text,
        "file_key" => file_key,
        "file_name" => file_name,
        "duration" => duration,
        "resources" => [
          %{
            "type" => msg_type,
            "file_key" => file_key,
            "file_name" => file_name,
            "duration" => duration
          }
        ]
      }
    else
      %{"summary" => nil, "resources" => []}
    end
  end

  defp normalize_inbound_content("interactive", content_json, _message_id) do
    text = extract_interactive_content(content_json)
    %{"summary" => text, "interactive" => content_json, "resources" => []}
  end

  defp normalize_inbound_content(msg_type, content_json, _message_id)
       when msg_type in [
              "share_chat",
              "share_user",
              "share_calendar_event",
              "calendar",
              "general_calendar",
              "system",
              "merge_forward",
              "location",
              "video_chat",
              "todo",
              "vote",
              "hongbao"
            ] do
    text = extract_share_card_content(content_json, msg_type)
    %{"summary" => text, "card" => content_json, "resources" => []}
  end

  defp normalize_inbound_content(msg_type, content_json, _message_id) do
    summary =
      if is_map(content_json) and map_size(content_json) > 0, do: "[#{msg_type}]", else: nil

    %{"summary" => summary, "raw" => content_json, "resources" => []}
  end

  defp extract_post_text(content_json, message_id) do
    post_content =
      cond do
        is_map(Map.get(content_json, "zh_cn")) ->
          Map.get(content_json, "zh_cn")

        is_list(Map.get(content_json, "content")) ->
          content_json

        true ->
          nil
      end

    case post_content do
      nil ->
        {nil, []}

      post_content ->
        title = Map.get(post_content, "title", "")
        content_blocks = Map.get(post_content, "content", [])

        {parts, resources} =
          Enum.reduce(content_blocks, {[], []}, fn block, {parts_acc, res_acc} ->
            if is_list(block) do
              {block_parts, block_resources} =
                Enum.reduce(block, {[], []}, fn
                  %{"tag" => "text", "text" => t}, {acc_parts, acc_res} ->
                    {[t | acc_parts], acc_res}

                  %{"tag" => "at", "user_name" => name}, {acc_parts, acc_res} ->
                    {["@#{name}" | acc_parts], acc_res}

                  %{"tag" => "a", "text" => text, "href" => href}, {acc_parts, acc_res} ->
                    text = if is_binary(text) and text != "", do: "#{text}(#{href})", else: href
                    {[text | acc_parts], acc_res}

                  %{"tag" => "img", "image_key" => image_key}, {acc_parts, acc_res} ->
                    {["[image]" | acc_parts],
                     [
                       %{"type" => "image", "image_key" => image_key, "message_id" => message_id}
                       | acc_res
                     ]}

                  %{"tag" => "media", "file_key" => file_key} = media, {acc_parts, acc_res} ->
                    {["[media]" | acc_parts],
                     [
                       %{
                         "type" => "media",
                         "file_key" => file_key,
                         "image_key" => Map.get(media, "image_key"),
                         "message_id" => message_id
                       }
                       | acc_res
                     ]}

                  %{"tag" => "emotion", "emoji_type" => emoji_type}, {acc_parts, acc_res} ->
                    {[":" <> to_string(emoji_type) <> ":" | acc_parts], acc_res}

                  %{"tag" => "code_block", "text" => text}, {acc_parts, acc_res} ->
                    {["```" <> to_string(text) <> "```" | acc_parts], acc_res}

                  %{"tag" => "hr"}, {acc_parts, acc_res} ->
                    {["---" | acc_parts], acc_res}

                  _, acc ->
                    acc
                end)

              {Enum.reverse(block_parts) ++ parts_acc, Enum.reverse(block_resources) ++ res_acc}
            else
              {parts_acc, res_acc}
            end
          end)

        parts = parts |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

        summary =
          cond do
            title != "" and parts != "" -> "#{title}\n#{parts}"
            title != "" -> title
            parts != "" -> parts
            true -> nil
          end

        {summary, resources}
    end
  end

  defp extract_share_card_content(content_json, msg_type) do
    case msg_type do
      "share_chat" -> "[shared chat: #{Map.get(content_json, "chat_id", "")}]"
      "share_user" -> "[shared user: #{Map.get(content_json, "user_id", "")}]"
      "share_calendar_event" -> calendar_summary(content_json, "shared calendar event")
      "calendar" -> calendar_summary(content_json, "calendar invitation")
      "general_calendar" -> calendar_summary(content_json, "calendar")
      "system" -> "[system message]"
      "merge_forward" -> "[merged forward messages]"
      "location" -> location_summary(content_json)
      "video_chat" -> "[video chat: #{Map.get(content_json, "topic", "")}]"
      "todo" -> todo_summary(content_json)
      "vote" -> vote_summary(content_json)
      "hongbao" -> "[红包]"
      _ -> "[#{msg_type}]"
    end
  end

  defp extract_interactive_content(card) when is_map(card) do
    elements = Map.get(card, "elements") || Map.get(card, :elements) || []
    header = Map.get(card, "header") || Map.get(card, :header)

    header_text =
      if is_map(header) do
        title = Map.get(header, "title") || Map.get(header, :title) || %{}
        Map.get(title, "content") || Map.get(title, :content) || ""
      else
        ""
      end

    body_parts = Enum.map(elements, &extract_card_element/1)
    parts = [header_text | body_parts] |> Enum.reject(&(&1 == ""))

    case parts do
      [] -> "[interactive card]"
      _ -> Enum.join(parts, "\n")
    end
  end

  defp extract_interactive_content(_), do: "[interactive card]"

  defp extract_card_element(%{"tag" => "div"} = el) do
    text_obj = Map.get(el, "text") || %{}
    Map.get(text_obj, "content") || Map.get(text_obj, :content) || ""
  end

  defp extract_card_element(%{"tag" => "markdown", "content" => content}), do: content

  defp extract_card_element(%{"tag" => "action"} = el) do
    actions = Map.get(el, "actions") || []

    Enum.map_join(actions, " ", fn action ->
      text_obj = Map.get(action, "text") || %{}
      "[" <> (Map.get(text_obj, "content") || "") <> "]"
    end)
  end

  defp extract_card_element(%{"tag" => "note"} = el) do
    elements = Map.get(el, "elements") || []

    Enum.map_join(elements, " ", fn note_el ->
      Map.get(note_el, "content") || ""
    end)
  end

  defp extract_card_element(%{"tag" => "column_set"} = el) do
    columns = Map.get(el, "columns") || []

    Enum.map_join(columns, " | ", fn col ->
      col_elements = Map.get(col, "elements") || []
      Enum.map_join(col_elements, " ", &extract_card_element/1)
    end)
  end

  defp extract_card_element(%{"tag" => "hr"}), do: "---"

  defp extract_card_element(_), do: ""

  defp get_tenant_access_token(state) do
    now = System.system_time(:second)

    if is_binary(state.tenant_access_token) and is_integer(state.tenant_access_token_expire_at) and
         state.tenant_access_token_expire_at > now + 60 do
      {:ok, state.tenant_access_token, state}
    else
      with {:ok, body} <-
             feishu_post(
               state,
               "/auth/v3/tenant_access_token/internal",
               %{"app_id" => state.app_id, "app_secret" => state.app_secret},
               []
             ),
           {:ok, token, expires_in} <- extract_tenant_token(body) do
        expire_at = now + expires_in

        {:ok, token,
         %{state | tenant_access_token: token, tenant_access_token_expire_at: expire_at}}
      end
    end
  end

  defp maybe_attach_inbound_media(%{metadata: metadata} = inbound, state) when is_map(metadata) do
    resources = Map.get(metadata, "resources", [])

    with resources when is_list(resources) and resources != [] <- resources,
         {:ok, media, state} <- hydrate_inbound_media(resources, state),
         true <- media != [] do
      {put_in(inbound, [:metadata, "media"], media), state}
    else
      _ -> {inbound, state}
    end
  end

  defp hydrate_inbound_media(resources, state) do
    Enum.reduce(resources, {:ok, [], state}, fn resource, {:ok, media_acc, acc_state} ->
      case hydrate_single_resource(resource, acc_state) do
        {:ok, nil, next_state} ->
          {:ok, media_acc, next_state}

        {:ok, media, next_state} ->
          {:ok, media_acc ++ [media], next_state}

        {:error, reason, next_state} ->
          Logger.warning("[Feishu] Failed to hydrate inbound media: #{inspect(reason)}")
          {:ok, media_acc, next_state}
      end
    end)
  end

  defp hydrate_single_resource(resource, state) when is_map(resource) do
    type = Map.get(resource, "type") || Map.get(resource, :type)

    case type do
      "image" ->
        image_key = Map.get(resource, "image_key") || Map.get(resource, :image_key)
        message_id = Map.get(resource, "message_id") || Map.get(resource, :message_id)

        if is_binary(image_key) and image_key != "" do
          case fetch_image_data_url(image_key, message_id, state) do
            {:ok, data_url, mime_type, new_state} ->
              {:ok,
               %{
                 "type" => "image",
                 "url" => data_url,
                 "mime_type" => mime_type,
                 "image_key" => image_key
               }, new_state}

            {:error, reason, new_state} ->
              {:error, reason, new_state}
          end
        else
          {:ok, nil, state}
        end

      _ ->
        {:ok, nil, state}
    end
  end

  defp hydrate_single_resource(_resource, state), do: {:ok, nil, state}

  defp fetch_image_data_url(image_key, message_id, state)
       when is_binary(image_key) and image_key != "" and is_binary(message_id) and
              message_id != "" do
    with {:ok, token, state} <- get_tenant_access_token(state),
         {:ok, response} <-
           feishu_get_binary(
             state,
             "/im/v1/messages/#{message_id}/resources/#{image_key}?type=image",
             [
               {"Authorization", "Bearer #{token}"}
             ]
           ),
         {:ok, body} <- extract_binary_body(response) do
      mime_type = binary_response_content_type(response)
      data_url = "data:#{mime_type};base64," <> Base.encode64(body)
      {:ok, data_url, mime_type, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch_image_data_url(_image_key, _message_id, state) do
    {:error, :missing_message_id_for_image_resource, state}
  end

  defp extract_binary_body(%{body: body}) when is_binary(body) and body != "", do: {:ok, body}
  defp extract_binary_body(body) when is_binary(body) and body != "", do: {:ok, body}
  defp extract_binary_body(other), do: {:error, {:invalid_binary_body, other}}

  defp binary_response_content_type(%{headers: headers}), do: headers_content_type(headers)
  defp binary_response_content_type(_), do: "image/jpeg"

  defp headers_content_type(headers) when is_list(headers) do
    Enum.find_value(headers, "image/jpeg", fn
      {"content-type", value} when is_binary(value) ->
        value

      {"Content-Type", value} when is_binary(value) ->
        value

      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type", do: value, else: nil

      _ ->
        nil
    end)
  end

  defp headers_content_type(headers) when is_map(headers) do
    Map.get(headers, "content-type") ||
      Map.get(headers, "Content-Type") ||
      "image/jpeg"
  end

  defp headers_content_type(_), do: "image/jpeg"

  defp do_send_local_image(chat_id, image_path, metadata, state) do
    metadata = stringify_keys(metadata || %{})

    with {:ok, image_key, state} <- upload_local_image(image_path, state),
         payload <- %{
           chat_id: to_string(chat_id),
           content: nil,
           metadata:
             metadata
             |> Map.put("msg_type", "image")
             |> Map.put("content_json", %{"image_key" => image_key})
         },
         {:ok, new_state} <-
           send_explicit_message(
             payload,
             to_string(chat_id),
             nil,
             "image",
             %{"image_key" => image_key},
             state
           ) do
      {:ok, new_state}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, new_state} -> {:error, reason, new_state}
    end
  end

  defp do_send(_payload, %{enabled: false} = state), do: {:ok, state}

  defp do_send(payload, state) do
    chat_id = Map.get(payload, :chat_id) || Map.get(payload, "chat_id") || ""
    content = Map.get(payload, :content) || Map.get(payload, "content") || ""
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    msg_type = metadata_get(metadata, "msg_type")
    content_json = metadata_get(metadata, "content_json")

    cond do
      not is_binary(chat_id) or chat_id == "" ->
        {:error, :invalid_chat_id, state}

      is_nil(content_json) and (not is_binary(content) or String.trim(content) == "") ->
        {:error, :invalid_content, state}

      state.app_id == "" or state.app_secret == "" ->
        {:error, :missing_credentials, state}

      true ->
        is_progress = Map.get(metadata, "_progress") || Map.get(metadata, :_progress)

        cond do
          is_binary(msg_type) and msg_type != "" ->
            send_explicit_message(payload, chat_id, content, msg_type, content_json, state)

          is_progress ->
            {:ok, state}

          true ->
            send_interactive_card(payload, chat_id, content, state)
        end
    end
  end

  defp send_explicit_message(payload, chat_id, content, msg_type, content_json, state) do
    with {:ok, token, state} <- get_tenant_access_token(state),
         {:ok, receive_id_type} <- outbound_receive_id_type(payload, chat_id),
         {:ok, encoded_content} <- build_outbound_content(msg_type, content, content_json),
         {:ok, _body} <-
           feishu_post(
             state,
             "/im/v1/messages?receive_id_type=#{receive_id_type}",
             %{
               "receive_id" => chat_id,
               "msg_type" => msg_type,
               "content" => encoded_content
             },
             [{"Authorization", "Bearer #{token}"}]
           ) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp build_outbound_content("text", content, nil) when is_binary(content) do
    {:ok, Jason.encode!(%{"text" => content})}
  end

  defp build_outbound_content("post", content, nil) when is_binary(content) do
    {:ok,
     Jason.encode!(%{
       "zh_cn" => %{
         "content" => [[%{"tag" => "md", "text" => content}]]
       }
     })}
  end

  defp build_outbound_content("interactive", content, nil) when is_binary(content) do
    {:ok, Jason.encode!(build_interactive_card(content))}
  end

  defp build_outbound_content(msg_type, _content, content_json)
       when msg_type in [
              "text",
              "post",
              "interactive",
              "image",
              "file",
              "audio",
              "media",
              "sticker",
              "share_chat",
              "share_user",
              "system"
            ] do
    with {:ok, normalized} <- normalize_outbound_content_json(content_json),
         :ok <- validate_explicit_message(msg_type, normalized) do
      {:ok, Jason.encode!(normalized)}
    end
  end

  defp build_outbound_content(msg_type, _content, _content_json),
    do: {:error, {:unsupported_msg_type, msg_type}}

  defp normalize_outbound_content_json(nil), do: {:error, :missing_content_json}

  defp normalize_outbound_content_json(content_json) when is_map(content_json),
    do: {:ok, stringify_keys(content_json)}

  defp normalize_outbound_content_json(content_json) when is_binary(content_json) do
    case Jason.decode(content_json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, {:invalid_content_json, other}}
      {:error, reason} -> {:error, {:invalid_content_json, reason}}
    end
  end

  defp normalize_outbound_content_json(other), do: {:error, {:invalid_content_json, other}}

  defp validate_explicit_message("text", %{"text" => text}) when is_binary(text) and text != "",
    do: :ok

  defp validate_explicit_message("post", %{"zh_cn" => %{} = _post}), do: :ok
  defp validate_explicit_message("interactive", %{}), do: :ok

  defp validate_explicit_message("image", %{"image_key" => key})
       when is_binary(key) and key != "", do: :ok

  defp validate_explicit_message(msg_type, %{"file_key" => key})
       when msg_type in ["file", "audio", "media", "sticker"] and is_binary(key) and key != "",
       do: :ok

  defp validate_explicit_message("share_chat", %{"chat_id" => key})
       when is_binary(key) and key != "",
       do: :ok

  defp validate_explicit_message("share_user", %{"user_id" => key})
       when is_binary(key) and key != "",
       do: :ok

  defp validate_explicit_message("system", %{"type" => type, "params" => %{} = _params})
       when is_binary(type) and type != "",
       do: :ok

  defp validate_explicit_message(msg_type, payload),
    do: {:error, {:invalid_explicit_content, msg_type, payload}}

  defp send_text(payload, chat_id, content, state) do
    with {:ok, token, state} <- get_tenant_access_token(state),
         {:ok, receive_id_type} <- outbound_receive_id_type(payload, chat_id),
         {:ok, _body} <-
           feishu_post(
             state,
             "/im/v1/messages?receive_id_type=#{receive_id_type}",
             %{
               "receive_id" => chat_id,
               "msg_type" => "text",
               "content" => Jason.encode!(%{"text" => content})
             },
             [{"Authorization", "Bearer #{token}"}]
           ) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_send_card_with_id(chat_id, content, metadata, state) do
    if not state.enabled or state.app_id == "" or state.app_secret == "" do
      {:error, :not_configured, state}
    else
      card = build_interactive_card(content)
      payload = %{metadata: metadata}

      with {:ok, token, state} <- get_tenant_access_token(state),
           {:ok, receive_id_type} <- outbound_receive_id_type(payload, chat_id),
           {:ok, body} <-
             feishu_post(
               state,
               "/im/v1/messages?receive_id_type=#{receive_id_type}",
               %{
                 "receive_id" => chat_id,
                 "msg_type" => "interactive",
                 "content" => Jason.encode!(card)
               },
               [{"Authorization", "Bearer #{token}"}]
             ) do
        message_id =
          get_in(body, ["data", "message_id"]) || ""

        {:ok, message_id, state}
      else
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp do_patch_card(message_id, content, state) do
    if not state.enabled or state.app_id == "" or state.app_secret == "" do
      {:error, :not_configured, state}
    else
      card = build_interactive_card(content)

      with {:ok, token, state} <- get_tenant_access_token(state),
           {:ok, _body} <-
             feishu_patch(
               state,
               "/im/v1/messages/#{message_id}",
               %{
                 "content" => Jason.encode!(card)
               },
               [{"Authorization", "Bearer #{token}"}]
             ) do
        {:ok, state}
      else
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp send_interactive_card(payload, chat_id, content, state) do
    card = build_interactive_card(content)

    with {:ok, token, state} <- get_tenant_access_token(state),
         {:ok, receive_id_type} <- outbound_receive_id_type(payload, chat_id),
         {:ok, _body} <-
           feishu_post(
             state,
             "/im/v1/messages?receive_id_type=#{receive_id_type}",
             %{
               "receive_id" => chat_id,
               "msg_type" => "interactive",
               "content" => Jason.encode!(card)
             },
             [{"Authorization", "Bearer #{token}"}]
           ) do
      {:ok, state}
    else
      {:error, reason} ->
        Logger.warning("[Feishu] Card send failed, falling back to text: #{inspect(reason)}")

        case send_text(payload, chat_id, content, state) do
          {:ok, new_state} -> {:ok, new_state}
          {:error, text_reason, text_state} -> {:error, text_reason, text_state}
        end
    end
  end

  defp build_interactive_card(content) do
    elements = build_card_elements(content)

    %{
      "config" => %{"wide_screen_mode" => true},
      "elements" => elements
    }
  end

  defp build_card_elements(content) do
    content
    |> String.split("\n")
    |> chunk_by_type()
    |> Enum.flat_map(&render_chunk/1)
  end

  defp chunk_by_type(lines) do
    {chunks, current} =
      Enum.reduce(lines, {[], nil}, fn line, {chunks, current} ->
        cond do
          String.starts_with?(line, "```") and current == nil ->
            lang = String.trim_leading(line, "`") |> String.trim()
            {chunks, {:code, lang, []}}

          match?({:code, _, _}, current) and String.starts_with?(line, "```") ->
            {:code, lang, code_lines} = current
            {chunks ++ [{:code_block, lang, Enum.reverse(code_lines)}], nil}

          match?({:code, _, _}, current) ->
            {:code, lang, code_lines} = current
            {chunks, {:code, lang, [line | code_lines]}}

          Regex.match?(~r/^\#{1,3}\s/, line) ->
            {chunks ++ [{:heading, line}], nil}

          Regex.match?(~r/^[-*]\s/, line) ->
            case current do
              {:list, items} ->
                {chunks, {:list, items ++ [line]}}

              _ ->
                chunks = if current, do: chunks ++ [current], else: chunks
                {chunks, {:list, [line]}}
            end

          Regex.match?(~r/^\d+\.\s/, line) ->
            case current do
              {:list, items} ->
                {chunks, {:list, items ++ [line]}}

              _ ->
                chunks = if current, do: chunks ++ [current], else: chunks
                {chunks, {:list, [line]}}
            end

          String.trim(line) == "" ->
            if current do
              {chunks ++ [current], nil}
            else
              {chunks, nil}
            end

          true ->
            case current do
              {:text, text_lines} ->
                {chunks, {:text, text_lines ++ [line]}}

              _ ->
                chunks = if current, do: chunks ++ [current], else: chunks
                {chunks, {:text, [line]}}
            end
        end
      end)

    if current, do: chunks ++ [current], else: chunks
  end

  defp render_chunk({:heading, line}) do
    {level, text} =
      cond do
        String.starts_with?(line, "### ") -> {3, String.trim_leading(line, "### ")}
        String.starts_with?(line, "## ") -> {2, String.trim_leading(line, "## ")}
        String.starts_with?(line, "# ") -> {1, String.trim_leading(line, "# ")}
        true -> {3, line}
      end

    tag =
      case level do
        1 -> "lark_md"
        _ -> "lark_md"
      end

    [%{"tag" => "div", "text" => %{"tag" => tag, "content" => "**#{text}**"}}]
  end

  defp render_chunk({:code_block, lang, lines}) do
    code = Enum.join(lines, "\n")
    lang_str = if lang != "", do: lang, else: "text"

    [
      %{
        "tag" => "div",
        "text" => %{
          "tag" => "lark_md",
          "content" => "```#{lang_str}\n#{code}\n```"
        }
      }
    ]
  end

  defp render_chunk({:list, items}) do
    md = Enum.join(items, "\n")
    [%{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => md}}]
  end

  defp render_chunk({:text, lines}) do
    text = Enum.join(lines, "\n")

    if String.trim(text) == "" do
      []
    else
      [%{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => text}}]
    end
  end

  defp render_chunk(_), do: []

  defp extract_tenant_token(%{"code" => 0, "tenant_access_token" => token, "expire" => expire})
       when is_binary(token) and is_integer(expire) do
    {:ok, token, expire}
  end

  defp extract_tenant_token(body), do: {:error, {:tenant_token_error, body}}

  defp outbound_receive_id_type(payload, chat_id) do
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    case metadata_get(metadata, "receive_id_type") do
      type when type in ["open_id", "chat_id", "user_id", "union_id", "email"] ->
        {:ok, type}

      _ ->
        if String.starts_with?(chat_id, "oc_") do
          {:ok, "chat_id"}
        else
          {:ok, "open_id"}
        end
    end
  end

  defp feishu_post(state, path, body, headers) do
    state.http_post_fun.(@feishu_api <> path, body, headers)
    |> normalize_req_response()
    |> normalize_feishu_response()
  end

  defp feishu_post_multipart(state, path, body, headers) do
    state.http_post_multipart_fun.(@feishu_api <> path, body, headers)
    |> normalize_req_response()
    |> normalize_feishu_response()
  end

  defp feishu_patch(_state, path, body, headers) do
    url = @feishu_api <> path

    Req.patch(url,
      json: body,
      headers: headers,
      receive_timeout: @default_send_timeout_ms,
      retry: false,
      finch: Req.Finch
    )
    |> normalize_req_response()
    |> normalize_feishu_response()
  end

  defp feishu_get_binary(state, path, headers) do
    state.http_get_fun.(@feishu_api <> path, headers)
    |> normalize_binary_response()
  end

  defp normalize_req_response({:ok, %{body: body}}), do: {:ok, body}
  defp normalize_req_response({:ok, body}) when is_map(body), do: {:ok, body}
  defp normalize_req_response({:error, reason}), do: {:error, reason}

  defp normalize_binary_response({:ok, %{status: status} = response})
       when is_integer(status) and status in 200..299,
       do: {:ok, response}

  defp normalize_binary_response({:ok, %{status_code: status} = response})
       when is_integer(status) and status in 200..299,
       do: {:ok, response}

  defp normalize_binary_response({:ok, %{body: body}} = response) when is_binary(body),
    do: {:ok, elem(response, 1)}

  defp normalize_binary_response({:ok, body}) when is_binary(body), do: {:ok, body}

  defp normalize_binary_response({:ok, response}),
    do: {:error, {:unexpected_binary_response, response}}

  defp normalize_binary_response({:error, reason}), do: {:error, reason}

  defp normalize_feishu_response({:ok, %{"code" => 0} = body}), do: {:ok, body}
  defp normalize_feishu_response({:ok, body}), do: {:error, {:feishu_api_error, body}}
  defp normalize_feishu_response({:error, reason}), do: {:error, reason}

  defp default_http_post(url, body, headers) do
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: @default_send_timeout_ms,
      retry: false,
      finch: Req.Finch
    )
  end

  defp default_http_post_multipart(url, body, headers) do
    Req.post(url,
      form_multipart: body,
      headers: headers,
      receive_timeout: @default_send_timeout_ms,
      retry: false,
      finch: Req.Finch
    )
  end

  defp default_http_get(url, headers) do
    Req.get(url,
      headers: headers,
      receive_timeout: @default_send_timeout_ms,
      retry: false,
      finch: Req.Finch
    )
  end

  defp extract_sender_open_id(sender) do
    sender_id = Map.get(sender, "sender_id") || Map.get(sender, :sender_id) || %{}
    open_id = Map.get(sender_id, "open_id") || Map.get(sender_id, :open_id)

    if is_binary(open_id), do: open_id, else: nil
  end

  defp trim_dedup_cache(ids) when length(ids) > @dedup_cache_max do
    Enum.take(ids, @dedup_cache_max)
  end

  defp trim_dedup_cache(ids), do: ids

  defp metadata_get(metadata, key) do
    Map.get(metadata, key) ||
      case key do
        "msg_type" -> Map.get(metadata, :msg_type)
        "content_json" -> Map.get(metadata, :content_json)
        "receive_id_type" -> Map.get(metadata, :receive_id_type)
        _ -> nil
      end
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp upload_local_image(image_path, state) when is_binary(image_path) and image_path != "" do
    expanded_path = Path.expand(image_path)

    cond do
      not File.exists?(expanded_path) ->
        {:error, {:local_image_not_found, expanded_path}, state}

      not File.regular?(expanded_path) ->
        {:error, {:local_image_not_regular_file, expanded_path}, state}

      true ->
        multipart = [
          image_type: "message",
          image:
            {File.stream!(expanded_path, [], 2048),
             filename: Path.basename(expanded_path), content_type: MIME.from_path(expanded_path)}
        ]

        with {:ok, token, state} <- get_tenant_access_token(state),
             {:ok, body} <-
               feishu_post_multipart(
                 state,
                 "/im/v1/images",
                 multipart,
                 [{"Authorization", "Bearer #{token}"}]
               ),
             image_key when is_binary(image_key) and image_key != "" <-
               get_in(body, ["data", "image_key"]) do
          {:ok, image_key, state}
        else
          {:error, reason} -> {:error, reason, state}
          other -> {:error, {:missing_image_key, other}, state}
        end
    end
  end

  defp upload_local_image(_, state), do: {:error, :invalid_local_image_path, state}

  defp calendar_summary(content_json, label) do
    summary = Map.get(content_json, "summary", "")
    start_time = Map.get(content_json, "start_time", "")
    end_time = Map.get(content_json, "end_time", "")
    "[#{label}: #{summary} #{start_time}-#{end_time}]"
  end

  defp location_summary(content_json) do
    name = Map.get(content_json, "name", "")
    longitude = Map.get(content_json, "longitude", "")
    latitude = Map.get(content_json, "latitude", "")
    "[location: #{name} #{longitude},#{latitude}]"
  end

  defp todo_summary(content_json) do
    summary =
      case Map.get(content_json, "summary") do
        %{"title" => title} -> title
        value when is_binary(value) -> value
        _ -> ""
      end

    due_time = Map.get(content_json, "due_time", "")
    "[todo: #{summary} due #{due_time}]"
  end

  defp vote_summary(content_json) do
    topic = Map.get(content_json, "topic", "")
    options = Map.get(content_json, "options", []) |> Enum.join(", ")
    "[vote: #{topic} #{options}]"
  end

  defp allowed?(_sender_id, []), do: true

  defp allowed?(sender_id, allow_from) do
    sender = to_string(sender_id)

    if sender in allow_from do
      true
    else
      sender
      |> String.split("|", trim: true)
      |> Enum.any?(&(&1 in allow_from))
    end
  end
end
