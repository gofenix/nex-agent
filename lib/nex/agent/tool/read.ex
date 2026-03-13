defmodule Nex.Agent.Tool.Read do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Security

  def name, do: "read"
  def description, do: "Read a file from the filesystem (restricted to workspace)"
  def category, do: :base

  def definition do
    %{
      name: "read",
      description:
        "Read a file from the filesystem. Paths are validated against allowed roots. Supports line range selection with offset and limit.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          offset: %{
            type: "integer",
            description: "Line offset (0-based, optional). Skip first N lines."
          },
          limit: %{
            type: "integer",
            description: "Max lines to read (optional). Like head -n or tail -n."
          }
        },
        required: ["path"]
      }
    }
  end

  def execute(%{"path" => path} = args, _ctx) do
    case Security.validate_path(path) do
      {:ok, expanded} ->
        if reserved_profile_shadow_path?(expanded) do
          {:error,
           "USER profile lives at workspace/USER.md. Use user_update or read workspace/USER.md directly."}
        else
          case File.read(expanded) do
            {:ok, content} ->
              # Apply line range selection if specified
              content = apply_line_range(content, args["offset"], args["limit"])

              # Truncate if still too large
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
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}

  defp reserved_profile_shadow_path?(expanded) do
    Enum.take(Path.split(expanded), -2) == ["memory", "USER.md"]
  end

  # Private helper for line range selection
  defp apply_line_range(content, nil, nil), do: content

  defp apply_line_range(content, offset, limit) do
    lines = String.split(content, "\n")
    offset = offset || 0
    total_lines = length(lines)

    # Default limit to remaining lines if not specified
    limit =
      case limit do
        nil -> total_lines - offset
        n when n > 0 -> n
        _ -> total_lines - offset
      end

    # Safety: do not exceed available lines
    limit = min(limit, total_lines - offset)
    limit = max(limit, 0)

    lines
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.join("\n")
  end
end
