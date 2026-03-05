defmodule Nex.Agent.Tool.Read do
  alias Nex.Agent.Security
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "read"
  def description, do: "Read file contents (only files within allowed directories)"
  def category, do: :base

  def definition do
    %{
      name: "read",
      description: "Read file contents (only files within allowed directories)",
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
    case Security.validate_path(path) do
      {:error, reason} ->
        {:error, reason}

      {:ok, validated_path} ->
        case File.read(validated_path) do
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
end
