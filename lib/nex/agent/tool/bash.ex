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
    cwd = Map.get(ctx, :cwd, File.cwd!())
    timeout = Map.get(ctx, :timeout, 30) * 1000

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], stderr_to_stdout: true, cd: cwd)
      end)

    result =
      try do
        Task.await(task, timeout)
      rescue
        _ ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end

    case result do
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

      {:error, :timeout} ->
        {:error, "Command timed out after #{div(timeout, 1000)} seconds"}
    end
  end
end
