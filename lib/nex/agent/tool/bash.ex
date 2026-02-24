defmodule Nex.Agent.Tool.Bash do
  @behaviour Nex.Agent.Tool.Behaviour

  def definition do
    %{
      name: "bash",
      description: "Execute bash commands (ls, grep, find, etc.)",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Command to execute"},
          timeout: %{type: "number", description: "Timeout in seconds (default: 30)", default: 30}
        },
        required: ["command"]
      }
    }
  end

  def execute(%{"command" => command}, ctx) do
    timeout = Map.get(ctx, :timeout, 30) * 1000
    cwd = Map.get(ctx, :cwd, File.cwd!())

    options = [
      stderr_to_stdout: true,
      cd: cwd,
      timeout: timeout
    ]

    case System.cmd("sh", ["-c", command], options) do
      {output, 0} ->
        truncated =
          if String.length(output) > 50000 do
            String.slice(output, 0, 50000) <> "\n\n[Output truncated]"
          else
            output
          end

        {:ok, %{content: truncated, exit_code: 0}}

      {output, exit_code} ->
        truncated =
          if String.length(output) > 50000 do
            String.slice(output, 0, 50000) <> "\n\n[Output truncated]"
          else
            output
          end

        {:ok, %{content: truncated, exit_code: exit_code}}
    end
  rescue
    err in [ErlangError] ->
      {:error, "Command failed: #{inspect(err)}"}
  end
end
