defmodule Nex.Agent do
  alias Nex.Agent.{Session, Runner}

  @type t :: %__MODULE__{
          session: Session.t(),
          provider: atom(),
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil
        }

  defstruct [
    :session,
    :provider,
    :model,
    :api_key,
    :base_url
  ]

  def start(opts \\ []) do
    provider = Keyword.get(opts, :provider, :anthropic)
    model = Keyword.get(opts, :model, default_model(provider))
    api_key = Keyword.get(opts, :api_key) || default_api_key(provider)
    base_url = Keyword.get(opts, :base_url)
    project = Keyword.get(opts, :project, Path.basename(File.cwd!()))
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if is_nil(api_key) do
      {:error, "No API key found. Set :api_key or #{env_var_name(provider)}"}
    else
      case Session.create(project, cwd) do
        {:ok, session} ->
          {:ok,
           %__MODULE__{
             session: session,
             provider: provider,
             model: model,
             api_key: api_key,
             base_url: base_url
           }}

        error ->
          error
      end
    end
  end

  def prompt(agent, prompt, opts \\ []) do
    provider = Keyword.get(opts, :provider, agent.provider)
    model = Keyword.get(opts, :model, agent.model)
    api_key = Keyword.get(opts, :api_key) || agent.api_key || default_api_key(provider)
    base_url = Keyword.get(opts, :base_url, agent.base_url)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case Runner.run(agent.session, prompt,
           provider: provider,
           model: model,
           api_key: api_key,
           base_url: base_url,
           cwd: cwd
         ) do
      {:ok, result, session} ->
        {:ok, result, %{agent | session: session}}

      {:error, reason, session} ->
        {:error, reason, %{agent | session: session}}
    end
  end

  def session_id(agent) do
    agent.session.id
  end

  def fork(agent) do
    case Session.fork(agent.session) do
      {:ok, forked_session} ->
        {:ok, %{agent | session: forked_session}}

      error ->
        error
    end
  end

  def abort(_agent) do
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
end
