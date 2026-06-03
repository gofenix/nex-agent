defmodule Nex.Agent.InboundWorker do
  @moduledoc """
  Consume inbound channel messages and route them through Nex.Agent.

  Session strategy is channel + chat scoped (e.g. `telegram:<chat_id>`).
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, MemoryUpdater, Workspace}

  @default_task_watchdog_timeout_ms 600_000
  @coding_task_timeout_seconds 1_800
  @watchdog_grace_ms 5_000

  defstruct [
    :config,
    :agent_start_fun,
    :agent_prompt_fun,
    :agent_abort_fun,
    :github_ack_fun,
    agents: %{},
    active_tasks: %{},
    agent_last_active: %{},
    pending_queue: %{}
  ]

  @type agent_start_fun :: (keyword() -> {:ok, term()} | {:error, term()})
  @type agent_prompt_fun :: (term(), String.t(), keyword() ->
                               {:ok, String.t(), term()} | {:error, term(), term()})
  @type agent_abort_fun :: (term() -> :ok | {:error, term()})
  @type github_ack_fun :: (String.t(), pos_integer(), String.t() -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          config: Config.t(),
          agent_start_fun: agent_start_fun(),
          agent_prompt_fun: agent_prompt_fun(),
          agent_abort_fun: agent_abort_fun(),
          github_ack_fun: github_ack_fun(),
          agents: %{String.t() => term()},
          active_tasks: %{String.t() => pid()},
          agent_last_active: %{String.t() => integer()},
          pending_queue: %{term() => :queue.queue()}
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
      github_ack_fun: Keyword.get(opts, :github_ack_fun, &default_github_ack/3),
      agents: %{},
      active_tasks: %{},
      agent_last_active: %{},
      pending_queue: %{}
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
    from_cron = metadata_flag?(payload, "_from_cron")
    from_subagent = metadata_flag?(payload, "_from_subagent")
    from_feishu_task = metadata_flag?(payload, "_from_feishu_task")
    from_github = metadata_flag?(payload, "_from_github")

    state =
      if from_cron or from_feishu_task or from_github,
        do: state,
        else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless result == :message_sent or from_cron or from_feishu_task or from_github or
             suppress_outbound?(result) do
      publish_outbound(payload, result)
    end

    maybe_enqueue_memory_refresh(updated_agent, payload, from_cron, from_subagent)

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason, updated_agent}, payload}, state) do
    from_cron = metadata_flag?(payload, "_from_cron")
    from_subagent = metadata_flag?(payload, "_from_subagent")
    from_feishu_task = metadata_flag?(payload, "_from_feishu_task")
    from_github = metadata_flag?(payload, "_from_github")

    state =
      if from_cron or from_feishu_task or from_github,
        do: state,
        else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless from_cron or from_feishu_task or from_github do
      publish_outbound(payload, "Error: #{format_reason(reason)}")
    end

    maybe_enqueue_memory_refresh(updated_agent, payload, from_cron, from_subagent)

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason}, payload}, state) do
    from_feishu_task = metadata_flag?(payload, "_from_feishu_task")
    from_github = metadata_flag?(payload, "_from_github")
    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}

    unless from_feishu_task or from_github do
      publish_outbound(payload, "Error: #{format_reason(reason)}")
    end

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:check_timeout, key, pid}, state) do
    if Map.get(state.active_tasks, key) == pid and Process.alive?(pid) do
      Logger.warning("[InboundWorker] Task #{inspect(key)} timed out, killing")
      Process.exit(pid, :kill)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if reason != :normal and reason != :killed do
      Logger.warning("[InboundWorker] Task process #{inspect(pid)} crashed: #{inspect(reason)}")
    end

    drained_keys =
      state.active_tasks
      |> Enum.filter(fn {_key, task_pid} -> task_pid == pid end)
      |> Enum.map(&elem(&1, 0))

    active_tasks =
      state.active_tasks
      |> Enum.reject(fn {_key, task_pid} -> task_pid == pid end)
      |> Map.new()

    state =
      drained_keys
      |> Enum.reduce(%{state | active_tasks: active_tasks}, fn key, acc ->
        maybe_drain_pending(acc, key)
      end)

    {:noreply, state}
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

        %{
          state
          | agents: Map.delete(state.agents, key),
            pending_queue: Map.delete(state.pending_queue, key)
        }

      cmd == "/stop" ->
        {count, state} = stop_session(state, key, session_key, workspace)
        dropped = :queue.len(Map.get(state.pending_queue, key, :queue.new()))
        state = %{state | pending_queue: Map.delete(state.pending_queue, key)}

        publish_outbound(
          payload,
          "Stopped #{count} task(s)#{if dropped > 0, do: ", dropped #{dropped} queued message(s)", else: ""}."
        )

        state

      true ->
        if Map.has_key?(state.active_tasks, key) do
          maybe_ack_github_received(payload, content, :queued, state)

          # Session already has an active task — queue this message
          queue = Map.get(state.pending_queue, key, :queue.new())
          queued = {session_key, workspace, content, payload}
          queue = :queue.in(queued, queue)
          queue_len = :queue.len(queue)

          Logger.info(
            "[InboundWorker] Queued message for busy session #{inspect(key)} (queue=#{queue_len})"
          )

          # Keep max 5 pending messages per session to prevent unbounded growth
          queue =
            if queue_len > 5 do
              {_, trimmed} = :queue.out(queue)
              Logger.warning("[InboundWorker] Dropped oldest queued message for #{inspect(key)}")
              trimmed
            else
              queue
            end

          %{state | pending_queue: Map.put(state.pending_queue, key, queue)}
        else
          maybe_ack_github_received(payload, content, :started, state)
          dispatch_async(state, key, session_key, workspace, content, payload)
        end
    end
  end

  defp dispatch_async(state, key, session_key, workspace, content, payload) do
    {channel, chat_id} = parse_session_key(session_key)

    {:ok, agent, state} = ensure_agent(state, key, session_key, workspace)
    parent = self()
    from_cron = metadata_flag?(payload, "_from_cron")
    from_subagent = metadata_flag?(payload, "_from_subagent")
    from_feishu_task = metadata_flag?(payload, "_from_feishu_task")
    from_github_project = metadata_flag?(payload, "_from_github_project")
    from_github = metadata_flag?(payload, "_from_github") or from_github_project
    media = extract_media(payload)

    prompt_content =
      cond do
        from_feishu_task -> feishu_task_prompt(content, payload)
        from_github -> github_prompt(content, payload)
        true -> content
      end

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

    task_opts =
      cond do
        from_feishu_task ->
          [
            history_limit: 0,
            force_skills: ["feishu-task-executor"],
            skip_consolidation: true,
            max_iterations: 10,
            timeout: @coding_task_timeout_seconds
          ]

        from_github ->
          opts = [
            history_limit: 0,
            force_skills: ["github-issue-executor"],
            skip_consolidation: true,
            max_iterations: 20,
            timeout: @coding_task_timeout_seconds
          ]

          if from_github_project do
            opts ++
              [
                first_iteration_tool_only: ["opencode_run"],
                first_iteration_tool_choice: "opencode_run"
              ]
          else
            opts
          end

        true ->
          []
      end

    unless from_cron or from_subagent or from_github do
      Nex.Agent.PersonalSummary.ensure_default_jobs(
        channel,
        chat_id,
        metadata: extract_metadata(payload),
        workspace: workspace
      )
    end

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        inbound_message_id = inbound_message_id(payload)

        if channel == "feishu" and not from_cron and not from_feishu_task do
          _ = Nex.Agent.Channel.Feishu.start_processing_reaction(inbound_message_id)
        end

        try do
          result =
            state.agent_prompt_fun.(
              agent,
              prompt_content,
              [
                channel: channel,
                chat_id: chat_id,
                on_progress: nil,
                workspace: workspace,
                schedule_memory_refresh: false,
                metadata: extract_metadata(payload)
              ]
              |> maybe_put_opt(:media, media)
              |> Kernel.++(cron_opts)
              |> Kernel.++(task_opts)
            )

          if channel == "feishu" and not from_cron and not from_feishu_task do
            outcome =
              case result do
                {:ok, _result, _updated_agent} -> :ok
                _ -> :error
              end

            _ = Nex.Agent.Channel.Feishu.finish_processing_reaction(inbound_message_id, outcome)
          end

          send(parent, {:async_result, key, result, payload})
        rescue
          e ->
            if channel == "feishu" and not from_cron and not from_feishu_task do
              _ = Nex.Agent.Channel.Feishu.finish_processing_reaction(inbound_message_id, :error)
            end

            send(parent, {:async_result, key, {:error, Exception.message(e)}, payload})
        catch
          kind, reason ->
            if channel == "feishu" and not from_cron and not from_feishu_task do
              _ = Nex.Agent.Channel.Feishu.finish_processing_reaction(inbound_message_id, :error)
            end

            send(
              parent,
              {:async_result, key, {:error, "#{kind}: #{inspect(reason)}"}, payload}
            )
        end
      end)

    Process.monitor(pid)
    Process.send_after(self(), {:check_timeout, key, pid}, task_watchdog_timeout_ms(payload))

    %{
      state
      | active_tasks: Map.put(state.active_tasks, key, pid),
        agent_last_active: Map.put(state.agent_last_active, key, System.system_time(:second))
    }
  end

  @doc false
  def task_watchdog_timeout_ms(payload) when is_map(payload) do
    if metadata_flag?(payload, "_from_feishu_task") or
         metadata_flag?(payload, "_from_github") or
         metadata_flag?(payload, "_from_github_project") do
      @coding_task_timeout_seconds * 1_000 + @watchdog_grace_ms
    else
      @default_task_watchdog_timeout_ms
    end
  end

  defp maybe_drain_pending(state, key) do
    case Map.get(state.pending_queue, key) do
      nil ->
        state

      queue ->
        case :queue.out(queue) do
          {{:value, {session_key, workspace, content, payload}}, rest} ->
            remaining =
              if :queue.is_empty(rest),
                do: Map.delete(state.pending_queue, key),
                else: Map.put(state.pending_queue, key, rest)

            state = %{state | pending_queue: remaining}

            Logger.info(
              "[InboundWorker] Draining queued message for #{inspect(key)} (remaining=#{:queue.len(rest)})"
            )

            dispatch_async(state, key, session_key, workspace, content, payload)

          {:empty, _} ->
            %{state | pending_queue: Map.delete(state.pending_queue, key)}
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

    # If a streaming card was created, update it instead of sending a new message
    card_mid = Map.get(payload, :_card_message_id)

    metadata =
      if is_binary(card_mid) and card_mid != "" do
        Map.put(metadata, "_update_message_id", card_mid)
      else
        metadata
      end

    Logger.info("InboundWorker publishing topic=#{inspect(outbound_topic)} chat_id=#{chat_id}")

    Bus.publish(outbound_topic, %{chat_id: chat_id, content: content, metadata: metadata})
  end

  defp maybe_ack_github_received(payload, content, status, state) do
    if metadata_flag?(payload, "_from_github") or metadata_flag?(payload, "_from_github_project") do
      metadata = extract_metadata(payload)
      repo = present_string(Map.get(metadata, "repo") || Map.get(metadata, :repo))

      issue_number =
        parse_positive_integer(
          Map.get(metadata, "issue_number") || Map.get(metadata, :issue_number)
        )

      if repo && issue_number do
        body = github_ack_body(content, status)
        start_github_ack_task(state.github_ack_fun, repo, issue_number, body)
      end
    end
  end

  defp start_github_ack_task(ack_fun, repo, issue_number, body) do
    task = fn ->
      try do
        case ack_fun.(repo, issue_number, body) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[InboundWorker] GitHub ack failed repo=#{repo} issue=#{issue_number} reason=#{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.warning(
            "[InboundWorker] GitHub ack crashed repo=#{repo} issue=#{issue_number} reason=#{Exception.message(e)}"
          )
      catch
        kind, reason ->
          Logger.warning(
            "[InboundWorker] GitHub ack crashed repo=#{repo} issue=#{issue_number} reason=#{inspect({kind, reason})}"
          )
      end
    end

    case Process.whereis(Nex.Agent.TaskSupervisor) do
      nil ->
        _pid = spawn(task)
        :ok

      _pid ->
        case Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, task) do
          {:ok, _pid} -> :ok
          {:error, _reason} -> spawn(task)
        end
    end
  end

  defp github_ack_body(content, :queued) do
    """
    已收到。

    目标：#{String.trim(content)}
    状态：当前已有任务在执行，已排队；前一个任务完成后会继续处理。
    """
    |> String.trim()
  end

  defp github_ack_body(content, :started) do
    """
    已收到。

    目标：#{String.trim(content)}
    状态：正在处理，会在完成后把结果和 PR / 验证信息更新到这里。
    """
    |> String.trim()
  end

  defp default_github_ack(repo, issue_number, body) do
    case System.cmd(
           "gh",
           ["issue", "comment", to_string(issue_number), "--repo", repo, "--body", body],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, %{exit_code: code, output: output}}
    end
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

  defp feishu_task_prompt(content, payload) do
    metadata = extract_metadata(payload)
    metadata_json = Jason.encode!(metadata, pretty: true)

    """
    You are handling a Feishu task dispatch event.

    Incoming command:
    #{content}

    Feishu task metadata:
    #{metadata_json}

    Mandatory behavior:
    - Follow the feishu-task-executor skill exactly.
    - Use the Feishu task_id from metadata.
    - Fetch task details with: lark-cli task tasks get --as user --format json --params '{"task_guid":"<task_id>","user_id_type":"open_id"}'
    - Resolve the target repository from the task details, @repo annotation, or workspace/tasks/repos.json.
    - Dispatch coding work with `opencode run --dangerously-skip-permissions` from the resolved repository.
    - Report progress/results back to the Feishu task with lark-cli task +comment/+complete/+reopen commands.

    Forbidden for this event:
    - Do not use the internal Nex personal task tool.
    - Do not run `lark-cli task get`; that command does not exist in this CLI.
    - Do not run `lark-cli task update` or `lark-cli task comment`; use `task +update`, `task +comment`, `task +complete`, and `task +reopen`.
    - Do not run `opencode -m` for the task prompt; `-m` selects a model and starts interactive mode. Use `opencode run --dangerously-skip-permissions`.
    - Do not use executor_status or executor_dispatch to inspect Nex background executors.
    - Do not answer conversationally until execution/reporting has been attempted.
    """
  end

  defp github_prompt(content, payload) do
    metadata = extract_metadata(payload)
    metadata_json = Jason.encode!(metadata, pretty: true)

    """
    You are handling a GitHub comment mention event.

    Incoming command:
    #{content}

    GitHub event metadata:
    #{metadata_json}

    Mandatory behavior:
    - Follow the github-issue-executor skill exactly.
    - Decide from the GitHub context whether to start, continue, retry, stop, report status, or ask a clarifying question.
    - Use the issue, PR, branch, work_dir, registry, and comment metadata as context; do not require a preclassified action.
    - If coding work is needed, use work_dir as the only execution directory and call the `opencode_run` tool. Do not call opencode through the bash tool.
    - `opencode_run` must receive work_dir, branch, repo, issue_number, issue_title, issue_body, model from metadata.opencode_model when present, and timeout: 1800 when those values are available.
    - `opencode_run` records the prompt, command metadata, model, stdout/stderr log, exit code, and git diff summary. Inspect its returned JSON before creating a PR.
    - After `opencode_run` returns, inspect its result and git diff, run verification if needed, create or update the PR yourself, and record useful state in tasks/github_items.json.
    - If the user's intent is unclear or risky, ask a concise clarifying question in GitHub instead of guessing.

    Forbidden for this event:
    - Do not use Feishu or lark-cli commands.
    - Do not use the internal Nex personal task tool.
    - Do not implement the issue yourself with read/edit/write tools.
    - Do not run opencode in a long-lived checkout such as /Users/fenix/github/* or /Users/fenix/repos/*.
    - Do not use `bash` for opencode execution; use `opencode_run` so logs and metadata are observable.
    - Do not spend turns inspecting the repo beyond what is required to run opencode.
    - Do not stop after saying what you will do when the intent is clear; execute the required shell commands.
    - Do not answer conversationally until execution/reporting has been attempted.

    Required coding tool call shape:
    opencode_run(work_dir: "<work_dir>", branch: "<branch>", repo: "<repo>", issue_number: <issue_number>, issue_title: "<issue_title>", issue_body: "<issue_body>", model: "<opencode_model>", timeout: 1800)
    """
  end

  defp metadata_flag?(payload, key) when is_binary(key) do
    metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    atom_key = safe_existing_atom(key)

    Map.get(metadata, key) == true or Map.get(metadata, atom_key) == true
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp inbound_message_id(payload) do
    metadata = extract_metadata(payload)

    Map.get(metadata, "message_id") ||
      Map.get(payload, :message_id) ||
      Map.get(payload, "message_id")
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
  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp maybe_enqueue_memory_refresh(_agent, _payload, true, _from_subagent), do: :ok
  defp maybe_enqueue_memory_refresh(_agent, _payload, _from_cron, true), do: :ok

  defp maybe_enqueue_memory_refresh(%Nex.Agent{} = agent, _payload, false, false) do
    MemoryUpdater.enqueue(
      agent.session,
      provider: agent.provider,
      model: agent.model,
      api_key: agent.api_key,
      base_url: agent.base_url,
      workspace: agent.workspace
    )
  end

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
