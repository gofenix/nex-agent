defmodule Nex.Agent.Tool.CustomTools do
  @moduledoc """
  Runtime management for workspace custom Elixir tools stored under ~/.nex/agent/workspace/tools.
  """

  alias Nex.Agent.Tool.Registry
  require Logger

  @tool_name_regex ~r/^[a-z][a-z0-9_]*$/

  @spec root_dir() :: String.t()
  def root_dir do
    Application.get_env(
      :nex_agent,
      :custom_tools_path,
      Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/tools")
    )
  end

  @spec ensure_root_dir() :: :ok
  def ensure_root_dir do
    File.mkdir_p!(root_dir())
    :ok
  end

  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@tool_name_regex, name)
  def valid_name?(_), do: false

  @spec tool_dir(String.t()) :: String.t()
  def tool_dir(name), do: Path.join(root_dir(), name)

  @spec source_path(String.t()) :: String.t()
  def source_path(name), do: Path.join(tool_dir(name), "tool.ex")

  @spec metadata_path(String.t()) :: String.t()
  def metadata_path(name), do: Path.join(tool_dir(name), "tool.json")

  @spec custom_module?(atom()) :: boolean()
  def custom_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Nex.Agent.Tool.Custom.")
  end

  def custom_module?(_), do: false

  @spec module_for_name(String.t()) :: atom()
  def module_for_name(name) do
    Module.concat([Nex.Agent.Tool.Custom, Macro.camelize(name)])
  end

  @spec name_for_module(atom()) :: String.t() | nil
  def name_for_module(module) when is_atom(module) do
    if custom_module?(module) do
      module
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.Nex.Agent.Tool.Custom.", "")
      |> Macro.underscore()
    end
  end

  def name_for_module(_), do: nil

  @spec list() :: [map()]
  def list do
    ensure_root_dir()

    root_dir()
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&detail/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec list_modules() :: [atom()]
  def list_modules do
    list()
    |> Enum.flat_map(fn tool ->
      case module_from_metadata(tool) do
        {:ok, module} -> [module]
        :error -> []
      end
    end)
  end

  @spec detail(String.t()) :: map() | nil
  def detail(name) do
    meta_path = metadata_path(name)

    if File.exists?(meta_path) do
      with {:ok, body} <- File.read(meta_path),
           {:ok, metadata} <- Jason.decode(body) do
        Map.merge(metadata, %{
          source_path: source_path(name),
          metadata_path: meta_path,
          definition: current_definition(name)
        })
      else
        _ -> nil
      end
    else
      nil
    end
  end

  @spec module_from_string(String.t()) :: {:ok, atom()} | :error
  def module_from_string(module) when is_binary(module) do
    case Regex.run(~r/^Nex\.Agent\.Tool\.Custom\.([A-Z][A-Za-z0-9]*)$/, module) do
      [_, custom_name] ->
        {:ok, Module.concat([Nex.Agent.Tool.Custom, custom_name])}

      _ ->
        :error
    end
  end

  @spec create(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create(name, description, content, opts \\ []) do
    created_by = Keyword.get(opts, :created_by, "user")

    cond do
      not valid_name?(name) ->
        {:error, "Invalid tool name. Use snake_case starting with a letter."}

      File.exists?(tool_dir(name)) ->
        {:error, "Custom tool already exists: #{name}"}

      registry_name_taken?(name) ->
        {:error, "Tool name already exists: #{name}"}

      true ->
        do_create(name, description, content, created_by)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(name) do
    case detail(name) do
      nil ->
        {:error, "Custom tool not found: #{name}"}

      _tool ->
        if Process.whereis(Registry), do: Registry.unregister(name)
        File.rm_rf!(tool_dir(name))
        :ok
    end
  end

  @spec load_module_from_source(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def load_module_from_source(path) do
    with {:ok, code} <- File.read(path),
         {:ok, module} <- extract_module_name_from_source(code),
         {:ok, compiled_module} <- compile_module(path, code) do
      if compiled_module == module do
        {:ok, module}
      else
        {:error, "Compiled module does not match declared module"}
      end
    end
  end

  @spec extract_module_name_from_source(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def extract_module_name_from_source(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] -> {:ok, Module.concat([module_str])}
      _ -> {:error, "Could not detect module name in tool source"}
    end
  end

  defp do_create(name, description, content, created_by) do
    expected_module = module_for_name(name)
    created_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with :ok <- ensure_root_dir(),
         :ok <- validate_tool_source(name, content, expected_module),
         :ok <- write_tool_files(name, description, content, created_by, created_at),
         {:ok, module} <- load_module_from_source(source_path(name)),
         :ok <- validate_loaded_tool(module, name),
         :ok <- register_module(module) do
      {:ok, detail(name)}
    else
      {:error, reason} ->
        File.rm_rf!(tool_dir(name))
        {:error, reason}
    end
  end

  defp validate_tool_source(name, content, expected_module) do
    with {:ok, module} <- extract_module_name_from_source(content),
         true <-
           module == expected_module ||
             {:error, "Module name must be #{inspect(expected_module)}"} do
      case Code.string_to_quoted(content) do
        {:ok, _quoted} -> :ok
        {:error, {_line, error, token}} -> {:error, "Invalid Elixir code: #{error} #{token}"}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "Invalid tool module for #{name}"}
    end
  end

  defp write_tool_files(name, description, content, created_by, timestamp) do
    dir = tool_dir(name)
    File.mkdir_p!(dir)
    File.write!(source_path(name), content)

    metadata = %{
      "name" => name,
      "module" => Atom.to_string(module_for_name(name)) |> String.replace_prefix("Elixir.", ""),
      "description" => description,
      "scope" => "global",
      "created_by" => created_by,
      "created_at" => timestamp,
      "updated_at" => timestamp,
      "origin" => "local"
    }

    File.write!(metadata_path(name), Jason.encode!(metadata, pretty: true))
    :ok
  end

  defp compile_module(path, code) do
    quoted = Code.string_to_quoted!(code)
    compiled = Code.compile_quoted(quoted, path)

    case compiled do
      [{module, binary} | _] ->
        :code.purge(module)
        :code.delete(module)
        {:module, _} = :code.load_binary(module, String.to_charlist(path), binary)
        {:ok, module}

      _ ->
        {:error, "Tool source did not compile to a module"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp validate_loaded_tool(module, expected_name) do
    Code.ensure_loaded(module)

    cond do
      not function_exported?(module, :name, 0) ->
        {:error, "Tool module must export name/0"}

      not function_exported?(module, :definition, 0) ->
        {:error, "Tool module must export definition/0"}

      not function_exported?(module, :execute, 2) ->
        {:error, "Tool module must export execute/2"}

      module.name() != expected_name ->
        {:error, "Tool name/0 must return #{expected_name}"}

      true ->
        :ok
    end
  end

  defp register_module(module) do
    if Process.whereis(Registry) do
      Registry.register(module)
    end

    :ok
  end

  defp registry_name_taken?(name) do
    if Process.whereis(Registry) do
      Registry.get(name) != nil
    else
      false
    end
  end

  defp current_definition(name) do
    if Process.whereis(Registry) && Process.whereis(Registry) != self() do
      case Registry.get(name) do
        nil ->
          nil

        module ->
          if is_atom(module) and function_exported?(module, :definition, 0) do
            module.definition()
          end
      end
    end
  end

  defp module_from_metadata(%{"name" => name, "module" => declared_module}) do
    expected_module = module_for_name(name)
    expected_declared = Atom.to_string(expected_module) |> String.replace_prefix("Elixir.", "")

    cond do
      not valid_name?(name) ->
        Logger.warning("[CustomTools] Ignoring invalid custom tool metadata for #{inspect(name)}")
        :error

      declared_module != expected_declared ->
        Logger.warning(
          "[CustomTools] Ignoring custom tool #{name}: metadata module #{declared_module} does not match #{expected_declared}"
        )

        :error

      true ->
        {:ok, expected_module}
    end
  end

  defp module_from_metadata(_tool), do: :error
end
