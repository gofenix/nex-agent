defmodule Nex.Agent.Tool.Read do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "read"
  def description, do: "Read a file from the filesystem"
  def category, do: :base

  def definition do
    %{
      name: "read",
      description: "Read a file from the filesystem",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"}
        },
        required: ["path"]
      }
    }
  end

  def execute(%{"path" => path}, _ctx) do
    case File.read(path) do
      {:ok, content} ->
        truncated =
          if byte_size(content) > 100_000 do
            String.slice(content, 0, 100_000) <> "\n\n[Output truncated]"
          else
            content
          end

        {:ok, truncated}

      {:error, reason} ->
        {:error, "Error reading file #{path}: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}
end
