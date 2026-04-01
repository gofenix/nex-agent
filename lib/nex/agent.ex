defmodule Nex.Agent do
  @moduledoc false

  alias Nex.Agent.{
    MemoryUpdater,
    Onboarding,
    Runner,
    Session,
    SessionManager,
    Skills,
    Workspace
  }

  @type t :: %__MODULE__{
          session_key: String.t(),
          session: Session.t(),
          provider: atom(),
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          tools: map(),
          workspace: String.t(),
          cwd: String.t(),
          max_iterations: pos_integer()
        }

  defstruct [
    :session_key,
    :session,
    :provider,
    :model,
    :api_key,
    :base_url,
    :tools,
    :workspace,
    :cwd,
    max_iterations: 10
  ]

  def start(opts \\ []) do
    :ok = Onboarding.ensure_initialized()
    workspace = Keyword.get(opts, :workspace, Workspace.root())
    :ok = Onboarding.ensure_workspace_initialized(workspace)
    :ok = Skills.load()

    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, default_model(provider))
    api_key = Keyword.get(opts, :api_key) || default_api_key(provider)
    base_url = Keyword.get(opts, :base_url)
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")
    tools = Keyword.get(opts, :tools, %{})

    session_key = "#{channel}:#{chat_id}"

    if is_nil(api_key) and provider != :ollama do
      {:error, "No API key found. Set :api_key or #{env_var_name(provider)}"}
    else
      session = SessionManager.get_or_create(session_key, workspace: workspace)

      {:ok,
       %__MODULE__{
         session_key: session_key,
         session: session,
         provider: provider,
         model: model,
         api_key: api_key,
         base_url: base_url,
         tools: tools,
         workspace: workspace,
         cwd: cwd,
         max_iterations: max_iterations
       }}
    end
  end

  def prompt(agent, prompt, opts \\ []) do
    provider = Keyword.get(opts, :provider, agent.provider)
    model = Keyword.get(opts, :model, agent.model)
    api_key = Keyword.get(opts, :api_key) || agent.api_key || default_api_key(provider)
    base_url = Keyword.get(opts, :base_url, agent.base_url)
    workspace = Keyword.get(opts, :workspace, agent.workspace || Workspace.root())
    cwd = Keyword.get(opts, :cwd, agent.cwd || File.cwd!())
    max_iterations = Keyword.get(opts, :max_iterations, agent.max_iterations)
    {default_channel, default_chat_id} = parse_session_key(agent.session_key)
    channel = Keyword.get(opts, :channel, default_channel)
    chat_id = Keyword.get(opts, :chat_id, default_chat_id)
    tools = Keyword.get(opts, :tools, agent.tools || %{})

    session_key = "#{channel}:#{chat_id}"
    skip_consolidation = Keyword.get(opts, :skip_consolidation, false)
    metadata = Keyword.get(opts, :metadata, %{})
    project = Keyword.get(opts, :project)
    schedule_memory_refresh = Keyword.get(opts, :schedule_memory_refresh, true)

    session =
      if skip_consolidation do
        # Cron: use ephemeral session, don't pollute user session
        Session.new("cron:#{channel}:#{chat_id}:#{System.unique_integer()}")
      else
        SessionManager.get_or_create(session_key, workspace: workspace)
      end

    on_progress = Keyword.get(opts, :on_progress)
    tools_filter = Keyword.get(opts, :tools_filter)
    media = Keyword.get(opts, :media)

    runner_opts =
      [
        provider: provider,
        model: model,
        api_key: api_key,
        base_url: base_url,
        tools: tools,
        cwd: cwd,
        max_iterations: max_iterations,
        session_key: session_key,
        channel: channel,
        chat_id: chat_id,
        workspace: workspace,
        metadata: metadata
      ]
      |> maybe_put(:project, project)
      |> maybe_put(:on_progress, on_progress)
      |> maybe_put(:tools_filter, tools_filter)
      |> maybe_put(:media, media)
      |> maybe_put(:llm_client, Keyword.get(opts, :llm_client))
      |> maybe_put(:llm_call_fun, Keyword.get(opts, :llm_call_fun))
      |> maybe_put(:req_llm_generate_text_fun, Keyword.get(opts, :req_llm_generate_text_fun))
      |> maybe_put(:history_limit, Keyword.get(opts, :history_limit))
      |> maybe_put(:skip_consolidation, Keyword.get(opts, :skip_consolidation))
      |> maybe_put(:skip_skills, Keyword.get(opts, :skip_skills))

    case Runner.run(session, prompt, runner_opts) do
      {:ok, result, session} ->
        unless skip_consolidation, do: SessionManager.save(session, workspace: workspace)
        maybe_enqueue_memory_refresh(session, schedule_memory_refresh, skip_consolidation, runner_opts)
        {:ok, result, %{agent | session: session, workspace: workspace, cwd: cwd}}

      {:error, reason, session} ->
        unless skip_consolidation, do: SessionManager.save(session, workspace: workspace)
        maybe_enqueue_memory_refresh(session, schedule_memory_refresh, skip_consolidation, runner_opts)
        {:error, reason, %{agent | session: session, workspace: workspace, cwd: cwd}}
    end
  end

  def session_id(agent) do
    agent.session.key
  end

  def fork(agent) do
    forked = Session.new("#{agent.session_key}_fork_#{:rand.uniform(9999)}")
    {:ok, %{agent | session: forked, session_key: forked.key}}
  end

  def abort(_agent) do
    :ok
  end

  def reset_session(channel, chat_id, opts \\ []) do
    session_key = "#{channel}:#{chat_id}"
    SessionManager.invalidate(session_key, opts)
    :ok
  end

  defp default_model(:anthropic), do: "claude-sonnet-4-20250514"
  defp default_model(:openai), do: "gpt-4o"
  defp default_model(:ollama), do: "llama3.1"
  defp default_model(_), do: "claude-sonnet-4-20250514"

  defp default_api_key(:anthropic), do: System.get_env("ANTHROPIC_API_KEY")
  defp default_api_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp default_api_key(:ollama), do: nil
  defp default_api_key(_), do: nil

  defp env_var_name(:anthropic), do: "ANTHROPIC_API_KEY"
  defp env_var_name(:openai), do: "OPENAI_API_KEY"
  defp env_var_name(_), do: "API_KEY"

  defp parse_session_key(nil), do: {"telegram", "default"}

  defp parse_session_key(session_key) do
    case String.split(to_string(session_key), ":", parts: 2) do
      [channel, chat_id] -> {channel, chat_id}
      _ -> {"telegram", "default"}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_enqueue_memory_refresh(_session, false, _skip_consolidation, _runner_opts), do: :ok
  defp maybe_enqueue_memory_refresh(_session, _schedule, true, _runner_opts), do: :ok

  defp maybe_enqueue_memory_refresh(session, true, false, runner_opts) do
    MemoryUpdater.enqueue(
      session,
      provider: Keyword.get(runner_opts, :provider),
      model: Keyword.get(runner_opts, :model),
      api_key: Keyword.get(runner_opts, :api_key),
      base_url: Keyword.get(runner_opts, :base_url),
      workspace: Keyword.get(runner_opts, :workspace),
      req_llm_generate_text_fun: Keyword.get(runner_opts, :req_llm_generate_text_fun),
      llm_call_fun: Keyword.get(runner_opts, :llm_call_fun)
    )
  end
end
