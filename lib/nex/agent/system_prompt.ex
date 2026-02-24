defmodule Nex.Agent.SystemPrompt do
  def build(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    """
    #{date_header()}
    #{project_context(cwd)}
    #{tool_descriptions()}
    #{guidelines()}
    """
  end

  defp date_header do
    now = DateTime.utc_now()
    "Date: #{now.year}-#{pad(now.month)}-#{pad(now.day)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp project_context(cwd) do
    agents_md = Path.join(cwd, "AGENTS.md")
    system_md = Path.join(cwd, "SYSTEM.md")

    ctx =
      []
      |> read_if_exists(agents_md, "## Project Instructions")
      |> read_if_exists(system_md, "## System Instructions")

    if ctx == [] do
      ""
    else
      Enum.join(ctx, "\n\n")
    end
  end

  defp read_if_exists(acc, path, header) do
    if File.exists?(path) do
      content = File.read!(path)
      acc ++ ["#{header}\n\n#{content}\n"]
    else
      acc
    end
  end

  defp tool_descriptions do
    """
    ## Tools

    read: Read file contents
    bash: Execute bash commands (ls, grep, find, etc.)
    edit: Make surgical edits to files (find exact text and replace)
    write: Create or overwrite files
    """
  end

  defp guidelines do
    """
    ## Guidelines

    - Use the least invasive tool possible
    - Prefer read over edit, edit over write
    - Always verify after writing/editing
    - Keep changes focused and minimal
    """
  end
end
