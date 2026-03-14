defmodule Nex.Agent.Tool.ListDir do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Security

  @max_depth 10
  @max_entries 5000

  def name, do: "list_dir"
  def description, do: "List directory contents with file metadata"
  def category, do: :base

  def definition do
    %{
      name: "list_dir",
      description:
        "List directory contents with file type, size, and modification time. Paths are validated against allowed roots. Recursive listing has depth and entry limits.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Directory path to list"},
          recursive: %{
            type: "boolean",
            description: "List recursively (default: false, max depth: 10)",
            default: false
          }
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
        |> Enum.take(@max_entries)
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
        {entries, _} =
          names
          |> Enum.sort()
          |> Enum.reduce({[], 0}, fn name, {acc, count} ->
            if count >= @max_entries do
              {acc, count}
            else
              full = Path.join(dir, name)
              info = file_info(full)

              if info.type == :directory do
                {sub_entries, new_count} = list_entries_recursive(full, name, 1, count)
                {acc ++ [{name <> "/", info} | sub_entries], new_count}
              else
                {acc ++ [{name, info}], count + 1}
              end
            end
          end)

        entries

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  defp list_entries_recursive(_dir, prefix, depth, count) when depth > @max_depth do
    {[{Path.join(prefix, "MAX_DEPTH_REACHED"), %{type: :error, size: 0, mtime: "?"}}], count + 1}
  end

  defp list_entries_recursive(dir, prefix, depth, count) do
    if count >= @max_entries do
      {[], count}
    else
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.reduce({[], count}, fn name, {acc, inner_count} ->
            if inner_count >= @max_entries do
              {acc, inner_count}
            else
              full = Path.join(dir, name)
              rel = Path.join(prefix, name)
              info = file_info(full)

              if info.type == :directory do
                {sub_entries, new_count} =
                  list_entries_recursive(full, rel, depth + 1, inner_count)

                {acc ++ [{rel <> "/", info} | sub_entries], new_count}
              else
                {acc ++ [{rel, info}], inner_count + 1}
              end
            end
          end)

        {:error, _} ->
          {[], count}
      end
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

    truncated =
      if length(entries) >= @max_entries do
        "\n\n[Output truncated: reached #{@max_entries} entry limit]"
      else
        ""
      end

    header <> Enum.join(lines, "\n") <> truncated
  end

  defp format_size(size) when size < 1024, do: "#{size}B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 1)}K"

  defp format_size(size) when size < 1024 * 1024 * 1024,
    do: "#{Float.round(size / (1024 * 1024), 1)}M"

  defp format_size(size), do: "#{Float.round(size / (1024 * 1024 * 1024), 1)}G"
end
