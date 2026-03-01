defmodule Nex.Agent.InboundWorker do
  @moduledoc """
  Consume inbound channel messages and route them through Nex.Agent.

  Session strategy is channel + chat scoped (e.g. `telegram:<chat_id>`).
  """

  use GenServer

  alias Nex.Agent.{Bus, Config}

  defstruct [:config, :agent_start_fun, :agent_prompt_fun, :agent_abort_fun, agents: %{}]

  @type agent_start_fun :: (keyword() -> {:ok, term()} | {:error, term()})
  @type agent_prompt_fun :: (term(), String.t() ->
                               {:ok, String.t(), term()} | {:error, term(), term()})
  @type agent_abort_fun :: (term() -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          config: Config.t(),
          agent_start_fun: agent_start_fun(),
          agent_prompt_fun: agent_prompt_fun(),
          agent_abort_fun: agent_abort_fun(),
          agents: %{String.t() => term()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec reset_session(String.t(), String.t()) :: :ok
  def reset_session(channel, chat_id) do
    GenServer.call(__MODULE__, {:reset_session, channel, chat_id})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: Keyword.get(opts, :config, Config.load()),
      agent_start_fun: Keyword.get(opts, :agent_start_fun, &Nex.Agent.start/1),
      agent_prompt_fun: Keyword.get(opts, :agent_prompt_fun, &Nex.Agent.prompt/2),
      agent_abort_fun: Keyword.get(opts, :agent_abort_fun, &Nex.Agent.abort/1),
      agents: %{}
    }

    Bus.subscribe(:inbound)
    {:ok, state}
  end

  @impl true
  def handle_call({:reset_session, channel, chat_id}, _from, state) do
    key = session_key(channel, chat_id)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, key)}}
  end

  @impl true
  def handle_info({:bus_message, :inbound, payload}, state) when is_map(payload) do
    case process_inbound(payload, state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason, new_state} ->
        publish_outbound(payload, "Error: #{format_reason(reason)}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp process_inbound(payload, state) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel") || "unknown"
    chat_id = payload_chat_id(payload)
    content = Map.get(payload, :content) || Map.get(payload, "content") || ""
    cmd = String.trim(content)
    key = session_key(channel, chat_id)

    cond do
      cmd == "" ->
        {:ok, state}

      cmd == "/new" ->
        publish_outbound(payload, "New session started.")
        {:ok, %{state | agents: Map.delete(state.agents, key)}}

      cmd == "/stop" ->
        state = abort_session_agent(state, key)
        publish_outbound(payload, "Stopped current task.")
        {:ok, state}

      true ->
        with {:ok, agent, state} <- ensure_agent(state, key),
             {:ok, result, updated_agent} <- state.agent_prompt_fun.(agent, content) do
          state = put_in(state.agents[key], updated_agent)
          publish_outbound(payload, result)
          {:ok, state}
        else
          {:error, reason, updated_agent} ->
            state = put_in(state.agents[key], updated_agent)
            {:error, reason, state}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp ensure_agent(state, key) do
    case Map.fetch(state.agents, key) do
      {:ok, agent} ->
        {:ok, agent, state}

      :error ->
        opts = agent_start_opts(state.config, key)

        case state.agent_start_fun.(opts) do
          {:ok, agent} -> {:ok, agent, put_in(state.agents[key], agent)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp agent_start_opts(config, session_key) do
    provider = String.to_atom(config.provider)

    [
      provider: provider,
      model: config.model,
      api_key: Config.get_current_api_key(config),
      base_url: Config.get_current_base_url(config),
      project: session_key,
      cwd: File.cwd!()
    ]
  end

  defp abort_session_agent(state, key) do
    case Map.fetch(state.agents, key) do
      {:ok, agent} ->
        _ = state.agent_abort_fun.(agent)
        %{state | agents: Map.delete(state.agents, key)}

      :error ->
        state
    end
  end

  defp publish_outbound(payload, content) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel") || "unknown"
    chat_id = payload_chat_id(payload)

    outbound_topic =
      case channel do
        "telegram" -> :telegram_outbound
        "http" -> :http_outbound
        _ -> :outbound
      end

    metadata =
      payload
      |> extract_metadata()
      |> Map.put_new("channel", channel)
      |> Map.put_new("chat_id", chat_id)

    Bus.publish(outbound_topic, %{chat_id: chat_id, content: content, metadata: metadata})
  end

  defp extract_metadata(payload) do
    existing = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    base = %{}

    base =
      maybe_put(
        base,
        "message_id",
        Map.get(payload, :message_id) || Map.get(payload, "message_id")
      )

    base = maybe_put(base, "user_id", Map.get(payload, :user_id) || Map.get(payload, "user_id"))

    if is_map(existing) do
      Map.merge(existing, base)
    else
      base
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp payload_chat_id(payload) do
    (Map.get(payload, :chat_id) || Map.get(payload, "chat_id") || "")
    |> to_string()
  end

  defp session_key(channel, chat_id), do: "#{channel}:#{chat_id}"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
