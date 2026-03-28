defmodule Nex.SkillRuntime.SkillRunner do
  @moduledoc false

  alias Nex.SkillRuntime.{Package, Validator}

  @spec execute(Package.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%Package{} = package, args, ctx \\ %{}) do
    timeout =
      args
      |> Map.get("timeout", Map.get(ctx, :timeout, 120))
      |> normalize_timeout()

    with :ok <- Validator.validate_package(package),
         {:ok, {:command, command, base_args}} <- Validator.detect_interpreter(package),
         cwd when is_binary(cwd) <- package.root_path do
      json_args = Jason.encode!(Map.drop(args, ["timeout"]))
      env = [{"NEX_SKILL_ARGS", json_args}]

      task =
        Task.async(fn ->
          System.cmd(command, base_args ++ [json_args], stderr_to_stdout: true, cd: cwd, env: env)
        end)

      case Task.yield(task, timeout) do
        {:ok, {output, 0}} ->
          {:ok, sanitize_output(output)}

        {:ok, {output, exit_code}} ->
          {:error, "Exit code #{exit_code}\n#{sanitize_output(output)}"}

        {:exit, reason} ->
          {:error, "Skill execution failed: #{inspect(reason)}"}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, "Skill timed out after #{div(timeout, 1000)} seconds"}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "invalid skill package"}
    end
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout * 1000

  defp normalize_timeout(timeout) when is_float(timeout) and timeout > 0,
    do: trunc(timeout * 1000)

  defp normalize_timeout(_), do: 120_000

  defp sanitize_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
    else
      Base.encode64(output)
    end
  end
end
