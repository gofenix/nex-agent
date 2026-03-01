defmodule Nex.Agent.Channel.Telegram do
  @moduledoc """
  Telegram channel (long polling only, webhook-free).
  """

  use GenServer

  alias Nex.Agent.{Bus, Config}

  @telegram_api "https://api.telegram.org"
  @default_poll_interval_ms 1_000
  @default_timeout_seconds 20

  defstruct [
    :token,
    :allow_from,
    :reply_to_message,
    :proxy,
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
    config = Keyword.get(opts, :config, Config.load())
    telegram = Config.telegram(config)

    state = %__MODULE__{
      token: Map.get(telegram, "token", ""),
      allow_from: Config.telegram_allow_from(config),
      reply_to_message: Config.telegram_reply_to_message?(config),
      proxy: Map.get(telegram, "proxy"),
      http_get_fun: Keyword.get(opts, :http_get_fun, &default_http_get/2),
      http_post_fun: Keyword.get(opts, :http_post_fun, &default_http_post/2),
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
    state = poll_updates(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :telegram_outbound, payload}, state) when is_map(payload) do
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case telegram_get(state, "getUpdates", update_params(state.offset)) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) ->
        handle_updates(updates, state)

      _ ->
        state
    end
  end

  defp drop_pending_updates(state) do
    case telegram_get(state, "getUpdates", %{timeout: 0, allowed_updates: ["message"]}) do
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

  defp handle_updates(updates, state) do
    Enum.reduce(updates, state, fn update, acc ->
      acc = update_offset(acc, update)

      case normalize_update(update) do
        {:ok, inbound} ->
          if allowed?(inbound.sender_id, acc.allow_from) do
            Bus.publish(:inbound, inbound)
          end

          acc

        :ignore ->
          acc
      end
    end)
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

  defp update_offset(state, %{"update_id" => update_id}) when is_integer(update_id) do
    current = state.offset || 0
    %{state | offset: max(current, update_id + 1)}
  end

  defp update_offset(state, _), do: state

  defp do_send(%{chat_id: chat_id, content: content} = payload, state)
       when is_binary(chat_id) and is_binary(content) do
    params = %{
      chat_id: chat_id,
      text: content
    }

    params = maybe_reply_params(params, payload, state)
    telegram_post(state, "sendMessage", params)
  end

  defp do_send(_payload, _state), do: :ok

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
      timeout: @default_timeout_seconds,
      allowed_updates: ["message"]
    }

    if is_integer(offset), do: Map.put(base, :offset, offset), else: base
  end

  defp telegram_get(state, method, params) do
    state.http_get_fun.(build_url(state, method), params)
    |> normalize_req_response()
  end

  defp telegram_post(state, method, body) do
    state.http_post_fun.(build_url(state, method), body)
    |> normalize_req_response()
  end

  defp normalize_req_response({:ok, %{body: body}}), do: {:ok, body}
  defp normalize_req_response({:ok, body}) when is_map(body), do: {:ok, body}
  defp normalize_req_response({:error, reason}), do: {:error, reason}

  defp build_url(state, method) do
    if is_binary(state.proxy) and state.proxy != "" do
      # proxy is configured for compatibility with config schema;
      # Req transport-level proxy wiring can be added later if needed.
      :ok
    end

    "#{@telegram_api}/bot#{state.token}/#{method}"
  end

  defp default_http_get(url, params) do
    Req.get(url, params: params, receive_timeout: (@default_timeout_seconds + 5) * 1000)
  end

  defp default_http_post(url, body) do
    Req.post(url, json: body, receive_timeout: (@default_timeout_seconds + 5) * 1000)
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
