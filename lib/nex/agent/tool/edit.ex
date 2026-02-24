defmodule Nex.Agent.Tool.Edit do
  @behaviour Nex.Agent.Tool.Behaviour

  def definition do
    %{
      name: "edit",
      description: "Make surgical edits to files (find exact text and replace)",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute path to file"},
          search: %{type: "string", description: "Exact text to find"},
          replace: %{type: "string", description: "Text to replace with"}
        },
        required: ["path", "search", "replace"]
      }
    }
  end

  def execute(%{"path" => path, "search" => search, "replace" => replace}, _ctx) do
    expanded_path = Path.expand(path)

    case File.read(expanded_path) do
      {:ok, content} ->
        do_edit(expanded_path, content, search, replace)

      {:error, reason} ->
        {:error, "Failed to read file: #{expanded_path}, error: #{reason}"}
    end
  end

  defp do_edit(path, content, search, replace) do
    case String.split(content, search, parts: 2) do
      [_] ->
        {:error, "Text not found in file: #{path}"}

      [prefix, rest] ->
        new_content = prefix <> replace <> rest

        case File.write(path, new_content) do
          :ok ->
            {:ok, %{success: true, path: path}}

          {:error, reason} ->
            {:error, "Failed to write file: #{path}, error: #{reason}"}
        end
    end
  end
end
