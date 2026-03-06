defmodule Nex.Agent.Tool.Write do
  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  def name, do: "write"
  def description, do: "Write content to a file. Writing .ex files auto-triggers compilation and hot-reload."
  def category, do: :base

  def definition do
    %{
      name: "write",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          content: %{type: "string", description: "Content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  def execute(%{"path" => path, "content" => content}, _ctx) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.write(path, content) do
      :ok ->
        if String.ends_with?(path, ".ex") do
          case auto_reload(path, content) do
            {:ok, module_name} ->
              {:ok, "File written and module #{module_name} hot-reloaded: #{path}"}

            {:error, reason} ->
              {:ok, "File written to #{path}, but hot-reload failed: #{reason}. Restart needed."}
          end
        else
          {:ok, "File written successfully: #{path}"}
        end

      {:error, reason} ->
        {:error, "Error writing file #{path}: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path and content are required"}

  defp auto_reload(path, content) do
    # Try to extract the module name from defmodule declaration
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] ->
        module = String.to_atom("Elixir.#{module_str}")

        try do
          quoted = Code.string_to_quoted!(content)
          [{mod, binary}] = Code.compile_quoted(quoted)
          :code.purge(mod)
          {:module, _} = :code.load_binary(mod, ~c"#{path}", binary)

          # Hot-swap in Registry if it's a Tool module
          if Process.whereis(Nex.Agent.Tool.Registry) do
            Code.ensure_loaded(mod)

            if function_exported?(mod, :name, 0) and function_exported?(mod, :execute, 2) do
              Nex.Agent.Tool.Registry.hot_swap(mod.name(), mod)
              Logger.info("[Write] Hot-swapped tool #{mod.name()} in Registry")
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
