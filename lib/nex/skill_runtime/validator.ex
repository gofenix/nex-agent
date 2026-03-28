defmodule Nex.SkillRuntime.Validator do
  @moduledoc false

  alias Nex.Agent.Security
  alias Nex.SkillRuntime.Package

  @max_file_size 2_000_000

  @spec validate_package(Package.t()) :: :ok | {:error, String.t()}
  def validate_package(%Package{} = package) do
    with :ok <- validate_structure(package),
         :ok <- validate_provenance(package),
         :ok <- validate_paths(package),
         :ok <- validate_execution(package) do
      :ok
    end
  end

  @spec detect_interpreter(Package.t()) ::
          {:ok, {:command, String.t(), [String.t()]}} | {:error, String.t()}
  def detect_interpreter(%Package{execution_mode: "knowledge"}),
    do: {:error, "knowledge package has no entry script"}

  def detect_interpreter(%Package{} = package) do
    entry_script = package.manifest.entry_script

    with true <-
           (is_binary(entry_script) and entry_script != "") ||
             {:error, "playbook package is missing entry_script"},
         path when is_binary(path) <-
           Package.safe_join(package.root_path, entry_script) ||
             {:error, "entry_script escapes package root"},
         true <- File.exists?(path) || {:error, "entry_script not found"} do
      ext = Path.extname(path)

      cond do
        ext == ".sh" ->
          {:ok, {:command, "bash", [path]}}

        ext == ".py" ->
          {:ok, {:command, "python3", [path]}}

        ext in [".js", ".mjs", ".cjs"] ->
          {:ok, {:command, "node", [path]}}

        shebang = read_shebang(path) ->
          detect_shebang_command(shebang, path)

        true ->
          {:error, "unsupported entry_script interpreter for #{entry_script}"}
      end
    end
  end

  defp validate_structure(%Package{} = package) do
    cond do
      not File.exists?(Path.join(package.root_path, "SKILL.md")) ->
        {:error, "SKILL.md not found"}

      byte_size(package.manifest.content || "") == 0 ->
        {:error, "SKILL.md body is empty"}

      package.execution_mode == "playbook" and not is_binary(package.manifest.entry_script) ->
        {:error, "playbook package must declare entry_script"}

      true ->
        :ok
    end
  end

  defp validate_provenance(%Package{source: nil}), do: :ok

  defp validate_provenance(%Package{} = package) do
    manifest = get_in(package.source, ["file_manifest"]) || %{}
    expected_checksum = get_in(package.source, ["package_checksum"])

    with :ok <- ensure_source_commit_present(package, manifest),
         :ok <- validate_manifest_files(package, manifest),
         :ok <- validate_package_checksum(package, manifest, expected_checksum) do
      :ok
    end
  end

  defp validate_paths(%Package{} = package) do
    bad_reference =
      package.manifest.references
      |> Enum.find(fn ref ->
        case Package.safe_join(package.root_path, ref) do
          nil -> true
          path -> not File.exists?(path)
        end
      end)

    cond do
      bad_reference ->
        {:error, "invalid reference path #{bad_reference}"}

      Enum.any?(package.files, &String.contains?(&1, "..")) ->
        {:error, "package contains invalid relative paths"}

      Enum.any?(package.files, fn file ->
        case File.stat(Package.safe_join(package.root_path, file)) do
          {:ok, %File.Stat{size: size}} -> size > @max_file_size
          _ -> false
        end
      end) ->
        {:error, "package contains oversized file"}

      true ->
        :ok
    end
  end

  defp validate_execution(%Package{execution_mode: "knowledge"}), do: :ok

  defp validate_execution(%Package{} = package) do
    with {:ok, {:command, interpreter, [path]}} <- detect_interpreter(package),
         :ok <- ensure_interpreter_available(interpreter),
         :ok <- validate_shell_script_if_needed(interpreter, path) do
      :ok
    end
  end

  defp ensure_interpreter_available("bash"), do: ensure_executable("bash")
  defp ensure_interpreter_available("python3"), do: ensure_executable("python3")
  defp ensure_interpreter_available("node"), do: ensure_executable("node")
  defp ensure_interpreter_available(command), do: ensure_executable(command)

  defp ensure_executable(command) do
    if System.find_executable(command) do
      :ok
    else
      {:error, "interpreter #{command} is not available"}
    end
  end

  defp validate_shell_script_if_needed("bash", path), do: validate_shell_script(path)
  defp validate_shell_script_if_needed(_interpreter, _path), do: :ok

  defp ensure_source_commit_present(_package, manifest) when map_size(manifest) == 0, do: :ok

  defp ensure_source_commit_present(%Package{} = package, _manifest) do
    if is_binary(get_in(package.source, ["source_commit"])) and
         get_in(package.source, ["source_commit"]) != "" do
      :ok
    else
      {:error, "missing source_commit for package provenance"}
    end
  end

  defp validate_manifest_files(_package, manifest) when map_size(manifest) == 0, do: :ok

  defp validate_manifest_files(%Package{} = package, manifest) do
    expected_files =
      manifest
      |> Map.keys()
      |> MapSet.new()

    actual_files =
      package.files
      |> Enum.reject(&(&1 == "source.json"))
      |> MapSet.new()

    cond do
      actual_files != expected_files ->
        missing = MapSet.difference(expected_files, actual_files) |> Enum.sort()
        unexpected = MapSet.difference(actual_files, expected_files) |> Enum.sort()

        {:error,
         "file_manifest mismatch" <>
           maybe_suffix(" missing=#{Enum.join(missing, ",")}", missing) <>
           maybe_suffix(" unexpected=#{Enum.join(unexpected, ",")}", unexpected)}

      true ->
        Enum.reduce_while(manifest, :ok, fn {relative_path, expected_file_checksum}, :ok ->
          case Package.safe_join(package.root_path, relative_path) do
            nil ->
              {:halt, {:error, "file_manifest path escapes package root: #{relative_path}"}}

            path ->
              case File.read(path) do
                {:ok, content} ->
                  actual = sha256(content)

                  if actual == expected_file_checksum do
                    {:cont, :ok}
                  else
                    {:halt, {:error, "checksum mismatch for #{relative_path}"}}
                  end

                {:error, _} ->
                  {:halt, {:error, "missing file_manifest entry #{relative_path}"}}
              end
          end
        end)
    end
  end

  defp validate_package_checksum(_package, manifest, _expected_checksum)
       when map_size(manifest) == 0,
       do: :ok

  defp validate_package_checksum(_package, _manifest, expected_checksum)
       when not is_binary(expected_checksum) or expected_checksum == "",
       do: {:error, "missing package_checksum for package provenance"}

  defp validate_package_checksum(%Package{} = package, _manifest, expected_checksum) do
    actual =
      package.files
      |> Enum.reject(&(&1 == "source.json"))
      |> Enum.sort()
      |> Enum.map(fn relative_path ->
        package.root_path
        |> Package.safe_join(relative_path)
        |> File.read!()
      end)
      |> Enum.join()
      |> sha256()

    if actual == expected_checksum do
      :ok
    else
      {:error, "package_checksum mismatch"}
    end
  end

  defp validate_shell_script(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(
      &(String.trim(&1) == "" or String.trim_leading(&1) |> String.starts_with?("#"))
    )
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case Security.validate_command(line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "unsafe shell content: #{reason}"}}
      end
    end)
  rescue
    error ->
      {:error, "failed to validate script: #{Exception.message(error)}"}
  end

  defp read_shebang(path) do
    case File.open(path, [:read]) do
      {:ok, io} ->
        line = IO.read(io, :line)
        File.close(io)

        case line do
          "#!" <> rest -> String.trim(rest)
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp detect_shebang_command(shebang, path) do
    cond do
      String.contains?(shebang, "bash") or String.contains?(shebang, "/sh") ->
        {:ok, {:command, "bash", [path]}}

      String.contains?(shebang, "python") ->
        {:ok, {:command, "python3", [path]}}

      String.contains?(shebang, "node") ->
        {:ok, {:command, "node", [path]}}

      true ->
        {:error, "unsupported shebang #{shebang}"}
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp maybe_suffix(_suffix, []), do: ""
  defp maybe_suffix(suffix, _items), do: suffix
end
