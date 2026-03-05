defmodule Nex.Agent.Tool.Edit do
  alias Nex.Agent.Security
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "edit"
  def description, do: "Make surgical edits to files (only within allowed directories)"
  def category, do: :base

  def definition do
    %{
      name: "edit",
      description: "Make surgical edits to files (only within allowed directories)",
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
    case Security.validate_path(path) do
      {:error, reason} ->
        {:error, reason}

      {:ok, validated_path} ->
        case File.read(validated_path) do
          {:ok, content} ->
            do_edit(validated_path, content, search, replace)

          {:error, reason} ->
            {:error, "Failed to read file: #{validated_path}, error: #{reason}"}
        end
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
