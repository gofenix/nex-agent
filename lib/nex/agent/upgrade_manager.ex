defmodule Nex.Agent.UpgradeManager do
  @moduledoc """
  Code upgrade manager for agent modules.

  Orchestrates source upgrades via `CodeUpgrade`. All successful upgrades
  are persisted via git commit + async push. Manual rollback is available
  through `CodeUpgrade.rollback/1`.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Audit, CodeUpgrade}

  @core_modules [
    Nex.Agent.Runner,
    Nex.Agent.Session,
    Nex.Agent.ContextBuilder,
    Nex.Agent.InboundWorker,
    Nex.Agent.Subagent,
    Nex.Agent.Gateway
  ]

  defstruct []

  @type t :: %__MODULE__{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Upgrade a module with new code.

  Returns `{:ok, %{version: version, hot_reload: hot_reload}}` or `{:error, reason}`.
  """
  @spec upgrade(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def upgrade(module, code, opts \\ []) do
    GenServer.call(__MODULE__, {:upgrade, module, code, opts}, 30_000)
  end

  @spec hot_upgrade(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def hot_upgrade(module, code, opts \\ []) do
    upgrade(module, code, Keyword.put(opts, :persist_git, false))
  end

  @doc """
  Check if a module is a core module.
  """
  @spec core_module?(atom()) :: boolean()
  def core_module?(module), do: module in @core_modules

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:upgrade, module, code, opts}, _from, state) do
    result = surgery(module, code, opts)
    {:reply, result, state}
  end

  # --- Private ---

  defp surgery(module, code, opts) do
    reason = Keyword.get(opts, :reason, "upgrade")
    persist_git = Keyword.get(opts, :persist_git, true)
    audit_opts = Keyword.take(opts, [:workspace])

    case CodeUpgrade.upgrade_module(module, code, validate: true) do
      {:ok, result} ->
        source_path = get_source_path(module)
        if persist_git do
          persist_evolution(module, source_path, reason)
        end

        Audit.append(
          "code.hot_upgraded",
          %{
            module: module |> Atom.to_string() |> String.replace_prefix("Elixir.", ""),
            reason: reason,
            persist_git: persist_git,
            version_id: get_in(result, [:version, :id]),
            restart_required: get_in(result, [:hot_reload, :restart_required]) == true
          },
          audit_opts
        )

        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  end

  defp persist_evolution(module, source_path, reason) do
    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      module_short =
        module
        |> to_string()
        |> String.replace_prefix("Elixir.Nex.Agent.", "")

      msg = "upgrade_code(#{module_short}): #{reason}"

      with {:ok, repo_root} <- git_repo_root(),
           {:ok, repo_relative_source_path} <- git_trackable_source_path(source_path, repo_root) do
        case System.cmd("git", ["add", repo_relative_source_path],
               stderr_to_stdout: true,
               cd: repo_root
             ) do
          {_, 0} ->
            case System.cmd("git", ["commit", "-m", msg], stderr_to_stdout: true, cd: repo_root) do
              {_, 0} ->
                Task.start(fn ->
                  System.cmd("git", ["push"], stderr_to_stdout: true, cd: repo_root)
                end)

                Logger.info("[UpgradeManager] Committed code upgrade: #{msg}")

              {output, _} ->
                Logger.debug("[UpgradeManager] Git commit skipped: #{String.trim(output)}")
            end

          {output, _} ->
            Logger.warning("[UpgradeManager] Git add failed: #{String.trim(output)}")
        end
      else
        {:skip, reason} ->
          Logger.debug("[UpgradeManager] Git persist skipped: #{reason}")

        {:error, reason} ->
          Logger.debug("[UpgradeManager] Git persist skipped: #{reason}")
      end
    end)
  end

  @doc false
  @spec git_trackable_source_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:skip, String.t()}
  def git_trackable_source_path(source_path, repo_root)

  def git_trackable_source_path(source_path, repo_root)
      when is_binary(source_path) and is_binary(repo_root) do
    source_abs = Path.expand(source_path)
    repo_abs = Path.expand(repo_root)

    cond do
      not File.exists?(source_abs) ->
        {:skip, "source file does not exist: #{source_abs}"}

      not path_within_repo?(source_abs, repo_abs) ->
        {:skip, "source outside git repo: #{source_abs}"}

      true ->
        {:ok, Path.relative_to(source_abs, repo_abs)}
    end
  end

  def git_trackable_source_path(_source_path, _repo_root), do: {:skip, "invalid source path"}

  defp git_repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, "not in git repo: #{String.trim(output)}"}
    end
  end

  defp path_within_repo?(source_abs, repo_abs) do
    relative = Path.relative_to(source_abs, repo_abs)

    relative == "." or
      (Path.type(relative) != :absolute and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp get_source_path(module) do
    CodeUpgrade.source_path(module)
  end
end
