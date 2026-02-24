defmodule Nex.Agent.Tool.Read do
  @behaviour Nex.Agent.Tool.Behaviour

  def definition do
    %{
      name: "read",
      description: "Read file contents",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute path to file"}
        },
        required: ["path"]
      }
    }
  end

  def execute(%{"path" => path}, _ctx) do
    case File.read(path) do
      {:ok, content} ->
        truncated =
          if String.length(content) > 50000 do
            String.slice(content, 0, 50000) <> "\n\n[Output truncated - file too large]"
          else
            content
          end

        {:ok, %{content: truncated}}

      {:error, reason} ->
        {:error, "Failed to read file: #{path}, error: #{reason}"}
    end
  end
end
