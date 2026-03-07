defmodule Nex.Agent.Tool.Read do
  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Security

  def name, do: "read"
  def description, do: "Read a file from the filesystem (restricted to workspace)"
  def category, do: :base

  def definition do
    %{
      name: "read",
      description: "Read a file from the filesystem. Paths are validated against allowed roots.",
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
    case Security.validate_path(path) do
      {:ok, expanded} ->
        case File.read(expanded) do
          {:ok, content} ->
            truncated =
              if byte_size(content) > 100_000 do
                String.slice(content, 0, 100_000) <> "\n\n[Output truncated]"
              else
                content
              end

            {:ok, truncated}

          {:error, reason} ->
            {:error, "Error reading file #{expanded}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}
end
