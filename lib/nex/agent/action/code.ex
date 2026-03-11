defmodule Nex.Agent.Action.Code do
  @moduledoc """
  Code evolution engine - runtime code modification and hot loading.

  This is the core of the self-evolving agent. It allows the agent to
  modify its own code and reload it without restarting.

  ## Safety

  - All changes are versioned
  - Failed compilations automatically rollback
  - Previous code is preserved for manual recovery
  """

  require Logger

  alias Nex.Agent.HotReload
  alias Nex.Agent.Tool.CustomTools

  @versions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/evolution")

  @doc """
  Execute a structured code action payload.
  """
  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(payload, _ctx) do
    module_str = Map.get(payload, "module")
    code = Map.get(payload, "code")
    reason = Map.get(payload, "reason") || "code evolution"

    cond do
      not is_binary(module_str) or String.trim(module_str) == "" ->
        {:error, "code action requires module"}

      not is_binary(code) or String.trim(code) == "" ->
        {:error, "code action requires code"}

      true ->
        module = String.to_atom("Elixir.#{module_str}")

        case upgrade_module(module, code, reason: reason, validate: true) do
          {:ok, %{version: version, hot_reload: hot_reload}} ->
            {:ok,
             %{
               module: module_str,
               version_id: Map.get(version, :id, "ok"),
               hot_reload: hot_reload,
               rollback: nil
             }}

          {:error, error} ->
            {:error, "Code action failed for #{module_str}: #{error}. Fix the code and try again."}
        end
    end
  end

  @doc """
  Upgrade a module with new code.

  Always creates a backup before upgrade. Validates code syntax,
  and optionally performs a health check after loading.

  ## Options

  * `:validate` - Run validation + health check (default: true)
  """
  @spec upgrade_module(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def upgrade_module(module, code, opts \\ []) do
    validate = Keyword.get(opts, :validate, true)
    reason = Keyword.get(opts, :reason, "upgrade")

    source_path = source_path(module)

    with :ok <- maybe_validate_code(validate, code),
         :ok <- create_backup(module, source_path),
         :ok <- write_source(source_path, code),
         {:ok, hot_reload} <- compile_and_load(module, code),
         :ok <- maybe_health_check(validate, module) do
      version = save_version(module, code)
      persist_evolution(module, source_path, reason)
      Logger.info("[Action.Code] Upgraded #{inspect(module)} -> version #{version.id}")
      {:ok, %{version: version, hot_reload: hot_reload}}
    else
      {:error, reason} ->
        Logger.warning("[Action.Code] Upgrade failed for #{inspect(module)}: #{inspect(reason)}")
        _ = rollback(module)
        {:error, to_error(reason)}
    end
  end

  @doc """
  Rollback to the previous version of a module.
  """
  @spec rollback(atom()) :: :ok | {:error, String.t()}
  def rollback(module) do
    versions = list_versions(module)

    if length(versions) > 1 do
      previous = Enum.at(versions, -2)
      source_path = source_path(module)
      write_source(source_path, previous.code)
      compile_and_load(module, previous.code)
      :ok
    else
      # Try backup file
      module_dir = Path.join(@versions_dir, to_string(module))
      backup_path = Path.join(module_dir, "backup.ex")

      if File.exists?(backup_path) do
        code = File.read!(backup_path)
        source_path = source_path(module)
        write_source(source_path, code)
        compile_and_load(module, code)
        :ok
      else
        {:error, "No previous version to rollback to"}
      end
    end
  end

  @doc """
  Rollback to a specific version.
  """
  @spec rollback(atom(), String.t()) :: :ok | {:error, String.t()}
  def rollback(module, version_id) do
    version = get_version(module, version_id)

    if version do
      source_path = source_path(module)
      write_source(source_path, version.code)
      compile_and_load(module, version.code)
      :ok
    else
      {:error, "Version not found"}
    end
  end

  @doc """
  List all versions of a module.
  """
  @spec list_versions(atom()) :: list(map())
  def list_versions(module) do
    module_dir = Path.join(@versions_dir, to_string(module))

    if File.exists?(module_dir) do
      module_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.reject(&(&1 == "backup.ex"))
      |> Enum.map(&read_version(module_dir, &1))
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(& &1.timestamp)
    else
      []
    end
  end

  @doc """
  Get a specific version.
  """
  @spec get_version(atom(), String.t()) :: map() | nil
  def get_version(module, version_id) do
    list_versions(module)
    |> Enum.find(&(&1.id == version_id))
  end

  @doc """
  Get the current version.
  """
  @spec current_version(atom()) :: map() | nil
  def current_version(module) do
    versions = list_versions(module)
    if versions != [], do: List.last(versions), else: nil
  end

  @doc """
  Check if a module can be evolved.
  """
  @spec can_evolve?(atom()) :: boolean()
  def can_evolve?(module) do
    Code.ensure_loaded?(module) or
      (CustomTools.custom_module?(module) and File.exists?(source_path(module)))
  end

  @doc """
  List all modules that can be evolved (agent modules).
  """
  @spec list_evolvable_modules() :: [atom()]
  def list_evolvable_modules do
    (app_modules() ++ CustomTools.list_modules())
    |> Enum.filter(&can_evolve?/1)
    |> Enum.uniq()
  end

  @doc """
  Get the source code of a module from disk.
  """
  @spec get_source(atom()) :: {:ok, String.t()} | {:error, String.t()}
  def get_source(module) do
    path = source_path(module)

    if File.exists?(path) do
      File.read(path)
    else
      {:error, "Source not found at #{path}"}
    end
  end

  @doc """
  Diff between current source and new code.
  """
  @spec diff(atom(), String.t()) :: String.t()
  def diff(module, new_code) do
    case get_source(module) do
      {:ok, current} ->
        old_lines = String.split(current, "\n")
        new_lines = String.split(new_code, "\n")

        removed = old_lines -- new_lines
        added = new_lines -- old_lines

        parts = []

        parts =
          if removed != [],
            do: parts ++ ["--- Removed:\n" <> Enum.join(removed, "\n")],
            else: parts

        parts =
          if added != [], do: parts ++ ["+++ Added:\n" <> Enum.join(added, "\n")], else: parts

        if parts == [], do: "No changes", else: Enum.join(parts, "\n\n")

      {:error, reason} ->
        "Cannot diff: #{reason}"
    end
  end

  # Private functions

  defp app_modules do
    case :application.get_key(:nex_agent, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end

  @doc """
  Get the source file path for a module.
  """
  @spec source_path(atom()) :: String.t()
  def source_path(module) do
    if CustomTools.custom_module?(module) do
      module
      |> CustomTools.name_for_module()
      |> CustomTools.source_path()
    else
      beam_path = :code.where_is_file(~c"#{module}.beam") |> to_string()

      cond do
        beam_path == "" or String.contains?(beam_path, "non_existing") or
            not File.exists?(beam_path) ->
          module_path =
            module
            |> to_string()
            |> String.replace_prefix("Elixir.", "")
            |> Macro.underscore()

          possible_paths = [
            Path.join([File.cwd!(), "lib", module_path <> ".ex"]),
            Path.join([File.cwd!(), "nex_agent", "lib", module_path <> ".ex"]),
            Path.join([File.cwd!(), "..", "nex_agent", "lib", module_path <> ".ex"])
          ]

          Enum.find(possible_paths, &File.exists?/1) || hd(possible_paths)

        true ->
          beam_path
          |> Path.rootname(".beam")
          |> Path.rootname(".ez")
          |> String.replace("_build/", "lib/")
          |> String.replace("/ebin/", "/lib/")
          |> String.replace_suffix("", ".ex")
      end
    end
  end

  defp maybe_validate_code(false, _code), do: :ok

  defp maybe_validate_code(true, code) do
    case validate_code_with_timeout(code) do
      :ok -> :ok
      {:error, reason} -> {:error, "Validation failed: #{reason}"}
    end
  end

  defp validate_code_with_timeout(code) do
    # Run validation in isolated process with timeout
    # This catches infinite loops or hangs during parsing
    parent = self()
    timeout_ms = 3000

    pid =
      spawn(fn ->
        result =
          try do
            Code.string_to_quoted!(code)
            :ok
          rescue
            e -> {:error, Exception.message(e)}
          end

        send(parent, {:validation_result, result})
      end)

    # Monitor the spawned process
    ref = Process.monitor(pid)

    receive do
      {:validation_result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Validation process crashed: #{inspect(reason)}"}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        {:error,
         "Validation timeout (#{timeout_ms}ms) - possible infinite loop in code structure"}
    end
  end

  defp maybe_health_check(false, _module), do: :ok

  defp maybe_health_check(true, module) do
    try do
      info = module.__info__(:functions)

      if is_list(info) do
        :ok
      else
        {:error, "Health check failed: module interface incomplete"}
      end
    rescue
      e -> {:error, "Health check failed: #{Exception.message(e)}"}
    end
  end

  defp compile_and_load(module, code) do
    hot_reload = HotReload.reload_expected(source_path(module), code, module)

    if hot_reload.reload_succeeded do
      {:ok, hot_reload}
    else
      {:error, hot_reload.reason}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp write_source(source_path, code) do
    dir = Path.dirname(source_path)
    File.mkdir_p!(dir)
    File.write(source_path, code)
  end

  defp create_backup(module, source_path) do
    module_dir = Path.join(@versions_dir, to_string(module))
    File.mkdir_p!(module_dir)

    if is_binary(source_path) and File.exists?(source_path) do
      backup_path = Path.join(module_dir, "backup.ex")
      File.copy!(source_path, backup_path)
    end

    :ok
  end

  defp save_version(module, code) do
    module_dir = Path.join(@versions_dir, to_string(module))
    File.mkdir_p!(module_dir)

    version_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    timestamp = DateTime.utc_now() |> DateTime.to_string()

    version = %{
      id: version_id,
      timestamp: timestamp,
      code: code,
      module: module
    }

    version_file = Path.join(module_dir, "#{version_id}.ex")
    File.write!(version_file, Jason.encode!(version))

    version
  end

  defp read_version(module_dir, filename) do
    version_path = Path.join(module_dir, filename)

    case File.read(version_path) do
      {:ok, content} -> Jason.decode!(content, keys: :atoms!)
      _ -> nil
    end
  rescue
    _ -> nil
  end

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
              Task.start(fn ->
                System.cmd("git", ["push"], stderr_to_stdout: true)
              end)

              Logger.info("[Action.Code] Committed evolution: #{msg}")

            {output, _} ->
              Logger.debug("[Action.Code] Git commit skipped: #{String.trim(output)}")
          end

        {output, _} ->
          Logger.warning("[Action.Code] Git add failed: #{String.trim(output)}")
      end
    end)
  end

  defp to_error({:error, reason}), do: to_error(reason)
  defp to_error(reason) when is_binary(reason), do: reason
  defp to_error(reason), do: inspect(reason)
end
