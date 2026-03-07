defmodule Nex.Agent.Tool.ListDir do
  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Security

  def name, do: "list_dir"
  def description, do: "List directory contents with file metadata"
  def category, do: :base

  def definition do
    %{
      name: "list_dir",
      description: "List directory contents with file type, size, and modification time. Paths are validated against allowed roots.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Directory path to list"},
          recursive: %{type: "boolean", description: "List recursively (default: false)", default: false}
        },
        required: ["path"]
      }
    }
  end

  def execute(%{"path" => path} = args, _ctx) do
    recursive = Map.get(args, "recursive", false)

    case Security.validate_path(path) do
      {:ok, expanded} ->
        if File.dir?(expanded) do
          entries = list_entries(expanded, recursive)
          {:ok, format_entries(expanded, entries)}
        else
          {:error, "Not a directory: #{expanded}"}
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}

  defp list_entries(dir, false) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(dir, name)
          {name, file_info(full)}
        end)

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  defp list_entries(dir, true) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          full = Path.join(dir, name)
          info = file_info(full)

          if info.type == :directory do
            [{name <> "/", info} | list_entries_recursive(full, name)]
          else
            [{name, info}]
          end
        end)

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  defp list_entries_recursive(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          full = Path.join(dir, name)
          rel = Path.join(prefix, name)
          info = file_info(full)

          if info.type == :directory do
            [{rel <> "/", info} | list_entries_recursive(full, rel)]
          else
            [{rel, info}]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp file_info(path) do
    case File.stat(path) do
      {:ok, stat} ->
        %{
          type: stat.type,
          size: stat.size,
          mtime: format_time(stat.mtime)
        }

      {:error, _} ->
        %{type: :unknown, size: 0, mtime: "?"}
    end
  end

  defp format_time({{y, m, d}, {h, min, _s}}) do
    "#{y}-#{pad(m)}-#{pad(d)} #{pad(h)}:#{pad(min)}"
  end

  defp format_time(_), do: "?"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp format_entries(dir, entries) do
    header = "Directory: #{dir}\n\n"

    lines =
      Enum.map(entries, fn
        {:error, reason} ->
          "  ERROR: #{inspect(reason)}"

        {name, info} ->
          type_char = if info.type == :directory, do: "d", else: "-"
          size_str = format_size(info.size)
          "#{type_char} #{String.pad_trailing(size_str, 10)} #{info.mtime}  #{name}"
      end)

    header <> Enum.join(lines, "\n")
  end

  defp format_size(size) when size < 1024, do: "#{size}B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 1)}K"
  defp format_size(size) when size < 1024 * 1024 * 1024, do: "#{Float.round(size / (1024 * 1024), 1)}M"
  defp format_size(size), do: "#{Float.round(size / (1024 * 1024 * 1024), 1)}G"
end
