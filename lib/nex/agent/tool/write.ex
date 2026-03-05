defmodule Nex.Agent.Tool.Write do
  alias Nex.Agent.Security
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "write"
  def description, do: "Create or overwrite files (only within allowed directories)"
  def category, do: :base

  def definition do
    %{
      name: "write",
      description: "Create or overwrite files (only within allowed directories)",
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
    case Security.validate_path(path) do
      {:error, reason} ->
        {:error, reason}

      {:ok, validated_path} ->
        case File.write(validated_path, content) do
          :ok ->
            {:ok, %{success: true, path: validated_path}}

          {:error, reason} ->
            {:error, "Failed to write file: #{path}, error: #{reason}"}
        end
    end
  end
end
