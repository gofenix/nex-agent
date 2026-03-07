defmodule Nex.Agent.Channel.Telegram do
  @moduledoc """
  Telegram channel (long polling only, webhook-free).
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config}

  @telegram_api "https://api.telegram.org"
  @default_poll_interval_ms 500
  @default_poll_timeout_seconds 30
  @default_send_timeout_ms 15_000

  defstruct [
    :token,
    :allow_from,
    :reply_to_message,
    :proxy,
    :finch_name,
    :http_get_fun,
    :http_post_fun,
    :offset,
    :poll_interval_ms,
    :enabled
  ]

  @type t :: %__MODULE__{
          token: String.t(),
          allow_from: [String.t()],
          reply_to_message: boolean(),
          proxy: String.t() | nil,
          finch_name: atom(),
          http_get_fun: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          http_post_fun: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          offset: integer() | nil,
          poll_interval_ms: pos_integer(),
          enabled: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), map()) :: :ok
  def send_message(chat_id, content, metadata \\ %{}) do
    Bus.publish(:telegram_outbound, %{
      chat_id: to_string(chat_id),
      content: content,
      metadata: metadata
    })
  end

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)

    config = Keyword.get(opts, :config, Config.load())
    telegram = Config.telegram(config)
    proxy = normalize_proxy(Map.get(telegram, "proxy"))
    finch_name = start_finch_pool(proxy)

    state = %__MODULE__{
      token: Map.get(telegram, "token", ""),
      allow_from: Config.telegram_allow_from(config),
      reply_to_message: Config.telegram_reply_to_message?(config),
      proxy: proxy,
      finch_name: finch_name,
      http_get_fun: Keyword.get(opts, :http_get_fun, &default_http_get/3),
      http_post_fun: Keyword.get(opts, :http_post_fun, &default_http_post/3),
      offset: nil,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      enabled: Config.telegram_enabled?(config)
    }

    Bus.subscribe(:telegram_outbound)
    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, %{enabled: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_continue(:bootstrap, %{token: ""} = state) do
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    state = drop_pending_updates(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, state) do
    parent = self()

    if Process.whereis(Nex.Agent.TaskSupervisor) do
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        result = do_poll(state)
        send(parent, {:poll_result, result})
      end)

      {:noreply, state}
    else
      # TaskSupervisor not available (e.g. test), fall back to sync
      {new_offset, inbounds} = do_poll(state)
      state = if new_offset, do: %{state | offset: new_offset}, else: state

      Enum.each(inbounds, fn inbound ->
        if allowed?(inbound.sender_id, state.allow_from) do
          Logger.info("Telegram inbound accepted sender=#{inbound.sender_id} chat_id=#{inbound.chat_id}")
          Bus.publish(:inbound, inbound)
        end
      end)

      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:poll_result, {new_offset, inbounds}}, state) do
    state = if new_offset, do: %{state | offset: new_offset}, else: state

    Enum.each(inbounds, fn inbound ->
      if allowed?(inbound.sender_id, state.allow_from) do
        Logger.info("Telegram inbound accepted sender=#{inbound.sender_id} chat_id=#{inbound.chat_id}")
        Bus.publish(:inbound, inbound)
      else
        Logger.warning("Telegram inbound denied by allow_from sender=#{inbound.sender_id}")
      end
    end)

    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :telegram_outbound, payload}, state) when is_map(payload) do
    Logger.debug("Telegram outbound message: #{inspect(payload)}")
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Runs in a separate Task — must not touch GenServer state directly.
  # Returns {new_offset | nil, [inbound_messages]}
  defp do_poll(state) do
    case telegram_get(state, "getUpdates", update_params(state.offset)) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) and updates != [] ->
        Logger.debug("Telegram poll updates_count=#{length(updates)}")
        extract_updates(updates, state.offset)

      {:ok, %{"ok" => true, "result" => []}} ->
        {nil, []}

      {:ok, %{"ok" => false} = body} ->
        Logger.warning("Telegram getUpdates returned not ok: #{inspect(body)}")
        {nil, []}

      {:error, reason} ->
        Logger.warning("Telegram getUpdates failed: #{inspect(reason)}")
        {nil, []}

      _ ->
        {nil, []}
    end
  end

  defp extract_updates(updates, current_offset) do
    {max_offset, inbounds} =
      Enum.reduce(updates, {current_offset || 0, []}, fn update, {max_off, acc} ->
        update_id = Map.get(update, "update_id", 0)
        new_max = max(max_off, update_id + 1)

        case normalize_update(update) do
          {:ok, inbound} -> {new_max, [inbound | acc]}
          :ignore -> {new_max, acc}
        end
      end)

    {max_offset, Enum.reverse(inbounds)}
  end

  defp drop_pending_updates(state) do
    case telegram_get(state, "getUpdates", %{timeout: 0}) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) and updates != [] ->
        next_offset =
          updates
          |> Enum.map(&Map.get(&1, "update_id", 0))
          |> Enum.max()
          |> Kernel.+(1)

        %{state | offset: next_offset}

      _ ->
        state
    end
  end

  defp normalize_update(%{"message" => message}) when is_map(message) do
    text = Map.get(message, "text") || Map.get(message, "caption")
    chat_id = get_in(message, ["chat", "id"])
    user_id = get_in(message, ["from", "id"])
    username = get_in(message, ["from", "username"])
    message_id = Map.get(message, "message_id")

    cond do
      is_nil(text) or String.trim(text) == "" ->
        :ignore

      is_nil(chat_id) or is_nil(user_id) ->
        :ignore

      true ->
        sender_id =
          if is_binary(username) and username != "" do
            "#{user_id}|#{username}"
          else
            to_string(user_id)
          end

        {:ok,
         %{
           channel: "telegram",
           chat_id: to_string(chat_id),
           sender_id: sender_id,
           user_id: to_string(user_id),
           message_id: message_id,
           content: text,
           raw: %{"message" => message},
           metadata: %{"message_id" => message_id, "user_id" => to_string(user_id)}
         }}
    end
  end

  defp normalize_update(_), do: :ignore

  defp do_send(%{chat_id: chat_id, content: content} = payload, state) do
    chat_id = to_string(chat_id)
    content = to_string(content)

    params = %{
      chat_id: chat_id,
      text: content
    }

    params = maybe_reply_params(params, payload, state)
    telegram_post(state, "sendMessage", params)
  end

  defp do_send(payload, _state) do
    Logger.error("Telegram do_send received invalid payload: #{inspect(payload)}")
    :ok
  end

  defp maybe_reply_params(params, payload, state) do
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    if state.reply_to_message do
      case Map.get(metadata, "message_id") || Map.get(metadata, :message_id) do
        nil -> params
        message_id -> Map.put(params, :reply_to_message_id, message_id)
      end
    else
      params
    end
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

  defp update_params(offset) do
    base = %{
      timeout: @default_poll_timeout_seconds
    }

    if is_integer(offset), do: Map.put(base, :offset, offset), else: base
  end

  defp telegram_get(state, method, params) do
    state.http_get_fun.(build_url(state, method), params, [finch: state.finch_name])
    |> normalize_req_response()
  end

  defp telegram_post(state, method, body) do
    state.http_post_fun.(build_url(state, method), body, [finch: state.finch_name])
    |> normalize_req_response()
  end

  defp normalize_req_response({:ok, %{body: body}}), do: {:ok, body}
  defp normalize_req_response({:ok, body}) when is_map(body), do: {:ok, body}
  defp normalize_req_response({:error, reason}), do: {:error, reason}

  defp build_url(state, method) do
    "#{@telegram_api}/bot#{state.token}/#{method}"
  end

  defp default_http_get(url, params, req_options) do
    finch_name = Keyword.get(req_options, :finch, Req.Finch)

    Req.get(url,
      params: params,
      receive_timeout: (@default_poll_timeout_seconds + 2) * 1000,
      retry: false,
      finch: finch_name
    )
  end

  defp default_http_post(url, body, req_options) do
    finch_name = Keyword.get(req_options, :finch, Req.Finch)

    Req.post(url,
      json: body,
      receive_timeout: @default_send_timeout_ms + 5_000,
      retry: false,
      finch: finch_name
    )
  end

  defp normalize_proxy(proxy) when is_binary(proxy) and proxy != "", do: proxy
  defp normalize_proxy(_), do: nil

  defp start_finch_pool(nil) do
    Req.Finch
  end

  defp start_finch_pool(proxy) do
    case parse_proxy(proxy) do
      {:ok, proxy_tuple} ->
        name = :"Nex.Agent.TelegramFinch"

        case Finch.start_link(
               name: name,
               pools: %{default: [conn_opts: [proxy: proxy_tuple]]}
             ) do
          {:ok, _pid} ->
            Logger.info("[Telegram] Started Finch pool with proxy #{proxy}")
            name

          {:error, {:already_started, _pid}} ->
            name

          {:error, reason} ->
            Logger.warning("[Telegram] Failed to start proxy Finch pool: #{inspect(reason)}, falling back to direct")
            Req.Finch
        end

      :error ->
        Logger.warning("[Telegram] Invalid proxy #{inspect(proxy)}, falling back to direct")
        Req.Finch
    end
  end

  defp parse_proxy(proxy) do
    case URI.parse(proxy) do
      %{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        proxy_port = port || if(scheme == "https", do: 443, else: 80)
        {:ok, {String.to_atom(scheme), host, proxy_port, []}}

      _ ->
        :error
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
