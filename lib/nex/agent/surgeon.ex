defmodule Nex.Agent.Surgeon do
  @moduledoc """
  Code surgeon — safe hot-reload orchestrator for agent modules.

  Routes upgrades based on module criticality:
  - **Limb modules** (tools/skills): direct Evolution.upgrade_module, immediate return
  - **Core modules** (Runner/Session/...): precision surgery with canary window,
    monitors InboundWorker/Subagent, auto-rollbacks on crash

  All successful upgrades are persisted via git commit + async push.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Evolution, Tool.Registry}

  @core_modules [
    Nex.Agent.Runner,
    Nex.Agent.Session,
    Nex.Agent.ContextBuilder,
    Nex.Agent.InboundWorker,
    Nex.Agent.Subagent,
    Nex.Agent.Gateway
  ]

  @canary_window_ms 10_000

  defstruct monitoring: nil

  @type t :: %__MODULE__{
          monitoring: nil | %{
            module: atom(),
            source_path: String.t(),
            reason: String.t(),
            old_beam: {atom(), binary(), charlist()},
            old_source: String.t() | nil,
            monitors: [reference()],
            timer: reference(),
            from: GenServer.from()
          }
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Upgrade a module with new code. Routes to normal or precision surgery
  based on whether the module is in @core_modules.

  Returns `{:ok, version}` or `{:error, reason}`.
  """
  @spec upgrade(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def upgrade(module, code, opts \\ []) do
    GenServer.call(__MODULE__, {:upgrade, module, code, opts}, 30_000)
  end

  @doc """
  Query current surgery status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if a module is a core (precision surgery) module.
  """
  @spec core_module?(atom()) :: boolean()
  def core_module?(module), do: module in @core_modules

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:upgrade, module, code, opts}, from, %{monitoring: nil} = state) do
    if core_module?(module) do
      case precision_surgery(module, code, opts, from, state) do
        {:monitoring, new_state} ->
          # Don't reply yet — will reply after canary window or crash
          {:noreply, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      result = normal_surgery(module, code, opts)
      {:reply, result, state}
    end
  end

  def handle_call({:upgrade, _module, _code, _opts}, _from, state) do
    {:reply, {:error, "Surgery in progress, try again later"}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      case state.monitoring do
        nil ->
          %{monitoring: nil}

        m ->
          remaining = Process.read_timer(m.timer) || 0
          %{monitoring: %{module: m.module, remaining_ms: remaining}}
      end

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitoring: m} = state)
      when is_map(m) do
    if ref in m.monitors do
      Logger.error("[Surgeon] Canary crash detected after upgrading #{inspect(m.module)}: #{inspect(reason)}")
      rollback_beam(m)
      GenServer.reply(m.from, {:error, "Canary crash: #{inspect(reason)}, rolled back"})
      cleanup_monitors(m)
      {:noreply, %{state | monitoring: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:canary_timeout, %{monitoring: m} = state) when is_map(m) do
    Logger.info("[Surgeon] Canary window passed for #{inspect(m.module)} — surgery successful")
    cleanup_monitors(m)

    GenServer.reply(m.from, {:ok, m.version})

    # Persist to git (async)
    persist_evolution(m.module, m.source_path, m.reason)

    {:noreply, %{state | monitoring: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: Normal surgery (limb modules) ---

  defp normal_surgery(module, code, opts) do
    reason = Keyword.get(opts, :reason, "upgrade")

    case Evolution.upgrade_module(module, code, validate: true) do
      {:ok, version} ->
        maybe_hot_swap_registry(module)
        source_path = get_source_path(module)
        persist_evolution(module, source_path, reason)
        {:ok, version}

      {:error, error} ->
        {:error, error}
    end
  end

  # --- Private: Precision surgery (core modules) ---

  defp precision_surgery(module, code, opts, from, state) do
    reason = Keyword.get(opts, :reason, "upgrade")

    # 1. Save old beam from memory
    old_beam =
      case :code.get_object_code(module) do
        {mod, binary, file} -> {mod, binary, file}
        :error -> nil
      end

    # Save old source for rollback
    source_path = get_source_path(module)
    old_source = if File.exists?(source_path), do: File.read!(source_path), else: nil

    # 2. Compile + load via Evolution
    case Evolution.upgrade_module(module, code, validate: true) do
      {:ok, version} ->
        maybe_hot_swap_registry(module)

        # 3. Start canary window
        monitors = start_canary_monitors()
        timer = Process.send_after(self(), :canary_timeout, @canary_window_ms)

        monitoring = %{
          module: module,
          source_path: source_path,
          reason: reason,
          old_beam: old_beam,
          old_source: old_source,
          monitors: monitors,
          timer: timer,
          from: from,
          version: version
        }

        {:monitoring, %{state | monitoring: monitoring}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp start_canary_monitors do
    targets = [Nex.Agent.InboundWorker, Nex.Agent.Subagent]

    Enum.flat_map(targets, fn name ->
      case Process.whereis(name) do
        nil -> []
        pid -> [Process.monitor(pid)]
      end
    end)
  end

  defp rollback_beam(%{old_beam: {mod, binary, file}} = m) do
    Logger.warning("[Surgeon] Rolling back #{inspect(m.module)} via beam binary")
    :code.purge(mod)
    :code.load_binary(mod, file, binary)

    # Also restore source file
    if m.old_source do
      File.write(m.source_path, m.old_source)
    end
  end

  defp rollback_beam(%{old_beam: nil} = m) do
    Logger.warning("[Surgeon] No old beam for #{inspect(m.module)}, attempting Evolution.rollback")
    Evolution.rollback(m.module)
  end

  defp cleanup_monitors(%{monitors: monitors, timer: timer}) do
    Enum.each(monitors, &Process.demonitor(&1, [:flush]))
    Process.cancel_timer(timer)
  end

  # --- Private: Git persistence ---

  defp persist_evolution(module, source_path, reason) do
    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      module_short =
        module
        |> to_string()
        |> String.replace_prefix("Elixir.Nex.Agent.", "")

      msg = "evolve(#{module_short}): #{reason}"

      case System.cmd("git", ["add", source_path], stderr_to_stdout: true) do
        {_, 0} ->
          case System.cmd("git", ["commit", "-m", msg], stderr_to_stdout: true) do
            {_, 0} ->
              # Push async, don't block
              Task.start(fn ->
                System.cmd("git", ["push"], stderr_to_stdout: true)
              end)

              Logger.info("[Surgeon] Committed evolution: #{msg}")

            {output, _} ->
              Logger.debug("[Surgeon] Git commit skipped: #{String.trim(output)}")
          end

        {output, _} ->
          Logger.warning("[Surgeon] Git add failed: #{String.trim(output)}")
      end
    end)
  end

  # --- Private: Helpers ---

  defp get_source_path(module) do
    Evolution.source_path(module)
  end

  defp maybe_hot_swap_registry(module) do
    if Process.whereis(Registry) do
      Code.ensure_loaded(module)

      if function_exported?(module, :name, 0) do
        tool_name = module.name()
        Registry.hot_swap(tool_name, module)
      end
    end
  end
end
