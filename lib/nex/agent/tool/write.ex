defmodule Nex.Agent.Tool.Write do
  @behaviour Nex.Agent.Tool.Behaviour

  def definition do
    %{
      name: "write",
      description: "Create or overwrite files",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute path to file"},
          content: %{type: "string", description: "Content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  def execute(%{"path" => path, "content" => content}, _ctx) do
    path = Path.expand(path)

    case File.write(path, content) do
      :ok ->
        {:ok, %{success: true, path: path}}

      {:error, reason} ->
        {:error, "Failed to write file: #{path}, error: #{reason}"}
    end
  end
end
