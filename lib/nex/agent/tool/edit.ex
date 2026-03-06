defmodule Nex.Agent.Tool.Edit do
  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

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
    case File.read(path) do
      {:ok, content} ->
        case String.split(content, search, parts: 2) do
          [_] ->
            {:error, "Text not found in file: #{path}"}

          [prefix, rest] ->
            new_content = prefix <> replace <> rest

            case File.write(path, new_content) do
              :ok ->
                if String.ends_with?(path, ".ex") do
                  case auto_reload(path, new_content) do
                    {:ok, module_name} ->
                      {:ok, "File edited and module #{module_name} hot-reloaded: #{path}"}

                    {:error, reason} ->
                      {:ok, "File edited: #{path}, but hot-reload failed: #{reason}. Restart needed."}
                  end
                else
                  {:ok, "File edited successfully: #{path}"}
                end

              {:error, reason} ->
                {:error, "Error writing file #{path}: #{inspect(reason)}"}
            end
        end

      {:error, reason} ->
        {:error, "Error reading file #{path}: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path, search, and replace are required"}

  defp auto_reload(path, content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] ->
        module = String.to_atom("Elixir.#{module_str}")

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
