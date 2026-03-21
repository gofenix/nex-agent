defmodule Nex.Agent.InboundWorker do
  @moduledoc """
  Consume inbound channel messages and route them through Nex.Agent.

  Session strategy is channel + chat scoped (e.g. `telegram:<chat_id>`).
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, Workspace}

  defstruct [
    :config,
    :agent_start_fun,
    :agent_prompt_fun,
    :agent_abort_fun,
    agents: %{},
    active_tasks: %{},
    agent_last_active: %{}
  ]

  @type agent_start_fun :: (keyword() -> {:ok, term()} | {:error, term()})
  @type agent_prompt_fun :: (term(), String.t(), keyword() ->
                               {:ok, String.t(), term()} | {:error, term(), term()})
  @type agent_abort_fun :: (term() -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          config: Config.t(),
          agent_start_fun: agent_start_fun(),
          agent_prompt_fun: agent_prompt_fun(),
          agent_abort_fun: agent_abort_fun(),
          agents: %{String.t() => term()},
          active_tasks: %{String.t() => pid()},
          agent_last_active: %{String.t() => integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec reset_session(String.t(), String.t(), keyword()) :: :ok
  def reset_session(channel, chat_id, opts \\ []) do
    GenServer.call(__MODULE__, {:reset_session, channel, chat_id, opts})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: Keyword.get(opts, :config, Config.load()),
      agent_start_fun: Keyword.get(opts, :agent_start_fun, &Nex.Agent.start/1),
      agent_prompt_fun: Keyword.get(opts, :agent_prompt_fun, &Nex.Agent.prompt/3),
      agent_abort_fun: Keyword.get(opts, :agent_abort_fun, &Nex.Agent.abort/1),
      agents: %{},
      active_tasks: %{},
      agent_last_active: %{}
    }

    Bus.subscribe(:inbound)
    Process.send_after(self(), :cleanup_stale_agents, 600_000)
    {:ok, state}
  end

  @impl true
  def handle_call({:reset_session, channel, chat_id, opts}, _from, state) do
    session_key = session_key(channel, chat_id)
    workspace = Keyword.get(opts, :workspace, Workspace.root())
    key = runtime_key(workspace, session_key)
    Nex.Agent.reset_session(channel, chat_id, workspace: workspace)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, key)}}
  end

  @impl true
  def handle_info({:bus_message, :inbound, payload}, state) when is_map(payload) do
    {:noreply, dispatch_inbound(payload, state)}
  end

  @impl true
  def handle_info({:async_result, key, {:ok, result, updated_agent}, payload}, state) do
    from_cron = get_in(payload, [:metadata, "_from_cron"]) == true

    # Don't overwrite user agent with cron's ephemeral agent
    state =
      if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless result == :message_sent or from_cron or suppress_outbound?(result) do
      publish_outbound(payload, result)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason, updated_agent}, payload}, state) do
    from_cron = get_in(payload, [:metadata, "_from_cron"]) == true

    state =
      if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless from_cron do
      publish_outbound(payload, "Error: #{format_reason(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason}, payload}, state) do
    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    publish_outbound(payload, "Error: #{format_reason(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:check_timeout, key, pid}, state) do
    if Map.get(state.active_tasks, key) == pid and Process.alive?(pid) do
      Logger.warning("[InboundWorker] Task #{key} timed out after 10 minutes, killing")
      Process.exit(pid, :kill)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if reason != :normal and reason != :killed do
      Logger.warning("[InboundWorker] Task process #{inspect(pid)} crashed: #{inspect(reason)}")
    end

    active_tasks =
      state.active_tasks
      |> Enum.reject(fn {_key, task_pid} -> task_pid == pid end)
      |> Map.new()

    {:noreply, %{state | active_tasks: active_tasks}}
  end

  @impl true
  def handle_info(:cleanup_stale_agents, state) do
    now = System.system_time(:second)
    # 1 hour TTL
    stale_cutoff = now - 3600

    stale_keys =
      state.agent_last_active
      |> Enum.filter(fn {key, last_active} ->
        last_active < stale_cutoff and not Map.has_key?(state.active_tasks, key)
      end)
      |> Enum.map(&elem(&1, 0))

    if stale_keys != [] do
      Logger.info("[InboundWorker] Cleaning up #{length(stale_keys)} stale agent session(s)")
    end

    agents = Map.drop(state.agents, stale_keys)
    agent_last_active = Map.drop(state.agent_last_active, stale_keys)

    Process.send_after(self(), :cleanup_stale_agents, 600_000)
    {:noreply, %{state | agents: agents, agent_last_active: agent_last_active}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch_inbound(payload, state) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel") || "unknown"
    chat_id = payload_chat_id(payload)
    session_key = session_key(channel, chat_id)
    workspace = payload_workspace(payload)
    content = Map.get(payload, :content) || Map.get(payload, "content") || ""
    content = normalize_inbound_content(content)
    cmd = String.trim(content)
    key = runtime_key(workspace, session_key)

    Logger.info(
      "InboundWorker received channel=#{channel} chat_id=#{chat_id} workspace=#{workspace} cmd=#{inspect(cmd)}"
    )

    cond do
      cmd == "" ->
        state

      cmd == "/new" ->
        state = cancel_active_task(state, key)
        publish_outbound(payload, "New session started.")
        %{state | agents: Map.delete(state.agents, key)}

      cmd == "/stop" ->
        {count, state} = stop_session(state, key, session_key, workspace)
        publish_outbound(payload, "Stopped #{count} task(s).")
        state

      true ->
        dispatch_async(state, key, session_key, workspace, content, payload)
    end
  end

  defp dispatch_async(state, key, session_key, workspace, content, payload) do
    {channel, chat_id} = parse_session_key(session_key)

    {:ok, agent, state} = ensure_agent(state, key, session_key, workspace)
    parent = self()
    from_cron = get_in(payload, [:metadata, "_from_cron"]) == true
    from_subagent = get_in(payload, [:metadata, "_from_subagent"]) == true
    on_progress = if from_cron, do: nil, else: build_progress_callback(payload)
    media = extract_media(payload)

    cron_opts =
      if from_cron,
        do: [
          history_limit: 0,
          tools_filter: :cron,
          skip_consolidation: true,
          max_iterations: 3,
          skip_skills: true
        ],
        else: []

    unless from_cron or from_subagent do
      Nex.Agent.PersonalSummary.ensure_default_jobs(
        channel,
        chat_id,
        metadata: extract_metadata(payload),
        workspace: workspace
      )
    end

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        try do
          result =
            state.agent_prompt_fun.(
              agent,
              content,
              [channel: channel, chat_id: chat_id, on_progress: on_progress, workspace: workspace]
              |> maybe_put_opt(:media, media)
              |> Kernel.++(cron_opts)
            )

          send(parent, {:async_result, key, result, payload})
        rescue
          e ->
            send(parent, {:async_result, key, {:error, Exception.message(e)}, payload})
        catch
          kind, reason ->
            send(
              parent,
              {:async_result, key, {:error, "#{kind}: #{inspect(reason)}"}, payload}
            )
        end
      end)

    Process.monitor(pid)
    Process.send_after(self(), {:check_timeout, key, pid}, 600_000)

    %{
      state
      | active_tasks: Map.put(state.active_tasks, key, pid),
        agent_last_active: Map.put(state.agent_last_active, key, System.system_time(:second))
    }
  end

  defp build_progress_callback(payload) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel")

    fn type, _content ->
      case type do
        type when type in [:tool_hint, :thinking, :stream_text] and is_binary(channel) ->
          # External chat channels should only receive deliberate user-facing replies.
          :ok

        _ ->
          :ok
      end
    end
  end

  defp cancel_active_task(state, key) do
    case Map.get(state.active_tasks, key) do
      nil ->
        state

      pid ->
        Process.exit(pid, :kill)
        %{state | active_tasks: Map.delete(state.active_tasks, key)}
    end
  end

  defp stop_session(state, key, session_key, workspace) do
    count =
      case Map.get(state.active_tasks, key) do
        nil ->
          0

        pid ->
          Process.exit(pid, :kill)
          1
      end

    subagent_count =
      if Process.whereis(Nex.Agent.Subagent) do
        {:ok, n} = Nex.Agent.Subagent.cancel_by_session(session_key, workspace: workspace)
        n
      else
        0
      end

    state = abort_session_agent(state, key)
    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    {count + subagent_count, state}
  end

  defp ensure_agent(state, key, session_key, workspace) do
    case Map.fetch(state.agents, key) do
      {:ok, agent} ->
        # Reload session from SessionManager to get latest state
        session = Nex.Agent.SessionManager.get_or_create(session_key, workspace: workspace)
        updated_agent = %{agent | session: session, workspace: workspace}
        {:ok, updated_agent, put_in(state.agents[key], updated_agent)}

      :error ->
        opts = agent_start_opts(session_key, workspace)

        session = Nex.Agent.SessionManager.get_or_create(session_key, workspace: workspace)

        Logger.info(
          "InboundWorker creating new agent session=#{session.key} for key=#{inspect(key)}"
        )

        provider = Keyword.get(opts, :provider, :openai)
        model = Keyword.get(opts, :model, "gpt-4o")
        api_key = Keyword.get(opts, :api_key)
        base_url = Keyword.get(opts, :base_url)
        cwd = Keyword.get(opts, :cwd, File.cwd!())
        max_iterations = Keyword.get(opts, :max_iterations, 40)

        agent = %Nex.Agent{
          session_key: session_key,
          session: session,
          provider: provider,
          model: model,
          api_key: api_key,
          base_url: base_url,
          workspace: workspace,
          cwd: cwd,
          max_iterations: max_iterations
        }

        {:ok, agent, put_in(state.agents[key], agent)}
    end
  end

  defp agent_start_opts(session_key, workspace) do
    config = Config.load()
    [channel, chat_id] = String.split(session_key, ":", parts: 2)
    provider = Config.provider_to_atom(config.provider)
    home = System.get_env("HOME", File.cwd!())

    [
      provider: provider,
      model: config.model,
      api_key: Config.get_current_api_key(config),
      base_url: Config.get_current_base_url(config),
      tools: config.tools,
      workspace: workspace,
      cwd: home,
      max_iterations: Config.get_max_iterations(config),
      channel: channel,
      chat_id: chat_id
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

  defp publish_outbound(payload, content, extra_meta \\ []) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel") || "unknown"
    chat_id = payload_chat_id(payload)

    outbound_topic =
      case channel do
        "telegram" -> :telegram_outbound
        "feishu" -> :feishu_outbound
        "discord" -> :discord_outbound
        "slack" -> :slack_outbound
        "dingtalk" -> :dingtalk_outbound
        "http" -> :http_outbound
        _ -> :outbound
      end

    metadata =
      payload
      |> extract_metadata()
      |> Map.put_new("channel", channel)
      |> Map.put_new("chat_id", chat_id)
      |> Map.merge(Map.new(extra_meta, fn {k, v} -> {to_string(k), v} end))

    Logger.info("InboundWorker publishing topic=#{inspect(outbound_topic)} chat_id=#{chat_id}")

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

  defp extract_media(payload) do
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    case Map.get(metadata, "media") || Map.get(metadata, :media) do
      media when is_list(media) and media != [] -> media
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Suppress LLM outputs that are clearly not real replies to the user.
  # Uses structural checks rather than keyword blocklists.
  defp suppress_outbound?(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      # Empty or whitespace-only
      trimmed == "" ->
        true

      # Pure punctuation / symbols (no letters or digits)
      Regex.match?(~r/\A[\p{P}\p{S}\s]*\z/u, trimmed) ->
        true

      # Wrapped in parentheses/brackets with no substance outside — e.g. "（xxx）"
      # Typical of LLM "stage directions" like "（静默等待）" or "(no response needed)"
      Regex.match?(~r/\A[(\[（【][^)\]）】]*[)\]）】]\z/u, trimmed) ->
        Logger.warning("[InboundWorker] Suppressed stage-direction output: #{inspect(trimmed)}")
        true

      true ->
        false
    end
  end

  defp suppress_outbound?(_), do: false

  defp normalize_inbound_content(content) when is_binary(content), do: content
  defp normalize_inbound_content(nil), do: ""
  defp normalize_inbound_content(content), do: inspect(content, printable_limit: 500, limit: 50)

  defp payload_chat_id(payload) do
    (Map.get(payload, :chat_id) || Map.get(payload, "chat_id") || "")
    |> to_string()
  end

  defp payload_workspace(payload) do
    workspace = Map.get(payload, :workspace) || Map.get(payload, "workspace")

    if is_binary(workspace) and String.trim(workspace) != "" do
      Path.expand(workspace)
    else
      Workspace.root() |> Path.expand()
    end
  end

  defp parse_session_key(key) do
    key_str = to_string(key)

    case String.split(key_str, ":", parts: 2) do
      [channel, chat_id] -> {channel, chat_id}
      [single] -> {single, ""}
      _ -> {"unknown", key_str}
    end
  end

  defp session_key(channel, chat_id), do: "#{channel}:#{chat_id}"
  defp runtime_key(workspace, session_key), do: {Path.expand(workspace), session_key}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
