defmodule Nex.Agent do
  @moduledoc false

  alias Nex.Agent.{
    Onboarding,
    Runner,
    Session,
    SessionManager,
    Skills
  }

  @type t :: %__MODULE__{
          session_key: String.t(),
          session: Session.t(),
          provider: atom(),
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
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
    :cwd,
    max_iterations: 10
  ]

  def start(opts \\ []) do
    :ok = Onboarding.ensure_initialized()
    :ok = Skills.load()

    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, default_model(provider))
    api_key = Keyword.get(opts, :api_key) || default_api_key(provider)
    base_url = Keyword.get(opts, :base_url)
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")

    session_key = "#{channel}:#{chat_id}"

    if is_nil(api_key) and provider != :ollama do
      {:error, "No API key found. Set :api_key or #{env_var_name(provider)}"}
    else
      session = SessionManager.get_or_create(session_key)

      {:ok,
       %__MODULE__{
         session_key: session_key,
         session: session,
         provider: provider,
         model: model,
         api_key: api_key,
         base_url: base_url,
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
    cwd = Keyword.get(opts, :cwd, agent.cwd || File.cwd!())
    max_iterations = Keyword.get(opts, :max_iterations, agent.max_iterations)
    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")

    session_key = "#{channel}:#{chat_id}"
    skip_consolidation = Keyword.get(opts, :skip_consolidation, false)

    session =
      if skip_consolidation do
        # Cron: use ephemeral session, don't pollute user session
        Session.new("cron:#{channel}:#{chat_id}:#{System.unique_integer()}")
      else
        SessionManager.get_or_create(session_key)
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
        cwd: cwd,
        max_iterations: max_iterations,
        session_key: agent.session_key,
        channel: channel,
        chat_id: chat_id
      ]
      |> maybe_put(:on_progress, on_progress)
      |> maybe_put(:tools_filter, tools_filter)
      |> maybe_put(:media, media)
      |> maybe_put(:llm_client, Keyword.get(opts, :llm_client))
      |> maybe_put(:history_limit, Keyword.get(opts, :history_limit))
      |> maybe_put(:skip_consolidation, Keyword.get(opts, :skip_consolidation))
      |> maybe_put(:skip_skills, Keyword.get(opts, :skip_skills))

    case Runner.run(session, prompt, runner_opts) do
      {:ok, result, session} ->
        unless skip_consolidation, do: SessionManager.save(session)
        {:ok, result, %{agent | session: session}}

      {:error, reason, session} ->
        unless skip_consolidation, do: SessionManager.save(session)
        {:error, reason, %{agent | session: session}}
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

  def reset_session(channel, chat_id) do
    session_key = "#{channel}:#{chat_id}"
    SessionManager.invalidate(session_key)
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
