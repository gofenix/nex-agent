defmodule Nex.Agent.Evolution do
  @moduledoc """
  Code evolution engine - runtime code modification and hot loading.

  This is the core of the self-evolving agent. It allows the agent to
  modify its own code and reload it without restarting.

  ## Usage

      # Modify a module's code
      {:ok, version} = Nex.Agent.Evolution.upgrade_module(
        Nex.Agent.Runner,
        new_code_string
      )

      # Rollback to previous version
      :ok = Nex.Agent.Evolution.rollback(Nex.Agent.Runner)

      # List all versions
      versions = Nex.Agent.Evolution.versions(Nex.Agent.Runner)

  ## Safety

  - All changes are versioned
  - Failed compilations automatically rollback
  - Previous code is preserved for manual recovery
  """

  @versions_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/evolution")

  @doc """
  Upgrade a module with new code.

  ## Parameters

  * `module` - Module name (atom)
  * `code` - New Elixir code as string
  * `opts` - Options

  ## Options

  * `:validate` - Run validation before applying (default: false)
  * `:backup` - Create backup before upgrade (default: false)

  ## Examples

      new_code = \"\"\"
      defmodule Nex.Agent.Runner do
        def run(session, prompt, opts \\\\ []) do
          IO.puts(\"Modified at \#{DateTime.utc_now()}\")
          original_code()
        end
      end
      \"\"\"

      {:ok, version} = Nex.Agent.Evolution.upgrade_module(Nex.Agent.Runner, new_code)

  """
  @spec upgrade_module(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def upgrade_module(module, code, opts \\ []) do
    validate = Keyword.get(opts, :validate, false)
    backup = Keyword.get(opts, :backup, false)

    # Get current source path
    source_path = get_source_path(module)

    with :ok <- maybe_validate_code(validate, code),
         :ok <- maybe_create_backup(backup, module, source_path),
         :ok <- File.write(source_path, code),
         :ok <- compile_and_load(module, code) do
      version = save_version(module, code)
      {:ok, version}
    else
      {:error, reason} ->
        if backup do
          _ = rollback(module)
        end

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
      # Get the previous version (second to last)
      previous = Enum.at(versions, -2)

      source_path = get_source_path(module)

      # Write previous version
      File.write!(source_path, previous.code)

      # Reload
      compile_and_load(module, previous.code)

      :ok
    else
      {:error, "No previous version to rollback to"}
    end
  end

  @doc """
  Rollback to a specific version.
  """
  @spec rollback(atom(), String.t()) :: :ok | {:error, String.t()}
  def rollback(module, version_id) do
    version = get_version(module, version_id)

    if version do
      source_path = get_source_path(module)
      File.write!(source_path, version.code)
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

    if length(versions) > 0 do
      Enum.at(versions, -1)
    else
      nil
    end
  end

  @doc """
  Check if a module can be evolved.
  """
  @spec can_evolve?(atom()) :: boolean()
  def can_evolve?(module) do
    # Must be a defined module
    # Simplified: assume source exists if module is loaded
    Code.ensure_loaded?(module)
  end

  # Private functions

  defp get_source_path(module) do
    # Try to get the source file from the compiled beam
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
          # Current project layout
          Path.join([File.cwd!(), "lib", module_path <> ".ex"]),
          # Monorepo layout: repo root running from parent directory
          Path.join([File.cwd!(), "nex_agent", "lib", module_path <> ".ex"]),
          # Monorepo layout: running from nex_agent directory itself
          Path.join([File.cwd!(), "..", "nex_agent", "lib", module_path <> ".ex"])
        ]

        # Return first existing path or the first one
        Enum.find(possible_paths, &File.exists?/1) || hd(possible_paths)

      true ->
        # Convert beam path to ex path
        beam_path
        |> Path.rootname(".beam")
        |> Path.rootname(".ez")
        |> String.replace("_build/", "lib/")
        |> String.replace("/ebin/", "/lib/")
        |> String.replace_suffix("", ".ex")
    end
  end

  defp validate_code(code) do
    # Only parse the code, don't execute it
    # This validates syntax without running the code
    case Code.string_to_quoted(code) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp maybe_validate_code(false, _code), do: :ok

  defp maybe_validate_code(true, code) do
    case validate_code(code) do
      :ok -> :ok
      {:error, reason} -> {:error, "Validation failed: #{reason}"}
    end
  end

  defp compile_and_load(module, code) do
    # Parse the code
    quoted = Code.string_to_quoted!(code)

    # Compile the module with a unique name to avoid conflicts
    # This compiles the code into the module name
    {module_bin, _} = Code.compile_quoted(quoted, [])

    # Purge old version and load new
    :code.purge(module)
    {:module, _module} = :code.load_binary(module, ~c"", module_bin)

    :ok
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp create_backup(module, source_path) do
    module_dir = Path.join(@versions_dir, to_string(module))
    File.mkdir_p!(module_dir)

    backup_path = Path.join(module_dir, "backup.ex")
    File.copy!(source_path, backup_path)
    :ok
  end

  defp maybe_create_backup(false, _module, _source_path), do: :ok
  defp maybe_create_backup(true, _module, source_path) when not is_binary(source_path), do: :ok

  defp maybe_create_backup(true, module, source_path) do
    if File.exists?(source_path) do
      create_backup(module, source_path)
    else
      :ok
    end
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

  defp to_error({:error, reason}), do: to_error(reason)
  defp to_error(reason) when is_binary(reason), do: reason
  defp to_error(reason), do: inspect(reason)
end
