defmodule Nex.Agent.Tool.Edit do
  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  alias Nex.Agent.Security

  def name, do: "edit"
  def description, do: "Make surgical edits to files by search and replace. Editing .ex files auto-triggers hot-reload."
  def category, do: :base

  def definition do
    %{
      name: "edit",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          search: %{type: "string", description: "Exact text to find"},
          replace: %{type: "string", description: "Text to replace with"}
        },
        required: ["path", "search", "replace"]
      }
    }
  end

  def execute(%{"path" => path, "search" => search, "replace" => replace}, _ctx) do
    case Security.validate_path(path) do
      {:ok, expanded} ->
        case File.read(expanded) do
          {:ok, content} ->
            case String.split(content, search, parts: 2) do
              [_] ->
                {:error, "Text not found in file: #{expanded}"}

              [prefix, rest] ->
                new_content = prefix <> replace <> rest

                case File.write(expanded, new_content) do
                  :ok ->
                    if String.ends_with?(expanded, ".ex") do
                      case auto_reload(expanded, new_content) do
                        {:ok, module_name} ->
                          {:ok, "File edited and module #{module_name} hot-reloaded: #{expanded}"}

                        {:error, reason} ->
                          {:ok, "File edited: #{expanded}, but hot-reload failed: #{reason}. Restart needed."}
                      end
                    else
                      {:ok, "File edited successfully: #{expanded}"}
                    end

                  {:error, reason} ->
                    {:error, "Error writing file #{expanded}: #{inspect(reason)}"}
                end
            end

          {:error, reason} ->
            {:error, "Error reading file #{expanded}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path, search, and replace are required"}

  defp auto_reload(path, content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] ->
        try do
          quoted = Code.string_to_quoted!(content)
          [{mod, binary}] = Code.compile_quoted(quoted)
          :code.purge(mod)
          {:module, _} = :code.load_binary(mod, ~c"#{path}", binary)

          if Process.whereis(Nex.Agent.Tool.Registry) do
            Code.ensure_loaded(mod)

            if function_exported?(mod, :name, 0) and function_exported?(mod, :execute, 2) do
              Nex.Agent.Tool.Registry.hot_swap(mod.name(), mod)
              Logger.info("[Edit] Hot-swapped tool #{mod.name()} in Registry")
            end
          end

          {:ok, module_str}
        rescue
          e ->
            {:error, Exception.message(e)}
        end

      _ ->
        {:error, "Could not detect module name in file"}
    end
  end
end
