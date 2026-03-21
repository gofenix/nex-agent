defmodule Nex.Agent.Executor do
  @moduledoc false

  alias Nex.Agent.{Audit, ProjectMemory, Workspace}

  @executor_names ~w(codex_cli claude_code_cli nex_local)
  @runs_file "runs.jsonl"

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    %{
      "executors" => Enum.map(@executor_names, &executor_status(&1, opts)),
      "recent_runs" => recent_runs(opts)
    }
  end

  @spec get_run(String.t(), keyword()) :: map() | nil
  def get_run(run_id, opts \\ []) when is_binary(run_id) do
    runs_file(opts)
    |> read_jsonl()
    |> Enum.find(&(&1["id"] == run_id))
  end

  @spec dispatch(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def dispatch(attrs, opts \\ []) when is_map(attrs) do
    Workspace.ensure!(opts)

    prompt =
      Map.get(attrs, "task") || Map.get(attrs, :task) || Map.get(attrs, "prompt") ||
        Map.get(attrs, :prompt)

    cwd = Map.get(attrs, "cwd") || Map.get(attrs, :cwd) || File.cwd!()
    requested = Map.get(attrs, "executor") || Map.get(attrs, :executor)

    project =
      Map.get(attrs, "project") || Map.get(attrs, :project) || ProjectMemory.detect_project(cwd)

    executor = requested || preferred_executor(opts)

    cond do
      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "task is required"}

      executor == "nex_local" ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "status" => "accepted",
            "exit_code" => 0,
            "output" =>
              "nex_local selected. Handle this task locally with the built-in tools unless an external executor is preferred."
          })

        persist_run(record, opts)
        {:ok, record}

      true ->
        case executor_config(executor, opts) do
          %{available: true} = config ->
            run_external_executor(prompt, executor, config, cwd, project, attrs, opts)

          %{configured: false} ->
            {:error,
             "Executor #{executor} is not configured. Add #{executor}.json under workspace/executors first."}

          %{available: false, executable: executable} ->
            {:error, "Executor #{executor} is configured but unavailable: #{executable}"}
        end
    end
  end

  @spec preferred_executor(keyword()) :: String.t()
  def preferred_executor(opts \\ []) do
    Enum.find_value(~w(codex_cli claude_code_cli), "nex_local", fn name ->
      config = executor_config(name, opts)
      if config.available, do: name
    end)
  end

  @spec recent_runs(keyword()) :: [map()]
  def recent_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    runs_file(opts)
    |> read_jsonl()
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @spec executor_status(String.t(), keyword()) :: map()
  def executor_status(name, opts \\ []) when name in @executor_names do
    if name == "nex_local" do
      %{
        "name" => name,
        "configured" => true,
        "available" => true,
        "prompt_mode" => "local",
        "executable" => "internal"
      }
    else
      config = executor_config(name, opts)

      %{
        "name" => name,
        "configured" => config.configured,
        "available" => config.available,
        "prompt_mode" => config.prompt_mode,
        "executable" => config.executable,
        "timeout" => config.timeout
      }
    end
  end

  defp run_external_executor(prompt, executor, config, cwd, project, attrs, opts) do
    id = generate_run_id()
    started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    command = config.executable
    args = build_args(config, prompt)
    cmd_opts = build_cmd_opts(config, prompt, cwd)

    case run_command(command, args, cmd_opts, config.timeout) do
      {:ok, {output, exit_code}} ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => if(exit_code == 0, do: "completed", else: "failed"),
            "command" => command,
            "args" => args,
            "exit_code" => exit_code,
            "output" => sanitize_output(output)
          })

        persist_run(record, opts)

        if exit_code == 0 do
          {:ok, record}
        else
          {:error, "Executor #{executor} failed with exit code #{exit_code}"}
        end

      {:error, :timeout} ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => "failed",
            "command" => command,
            "args" => args,
            "error" => "timed out after #{config.timeout}s"
          })

        persist_run(record, opts)
        {:error, "Executor #{executor} timed out after #{config.timeout}s"}

      {:error, reason} ->
        message = Exception.format_banner(:error, reason)

        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => "failed",
            "command" => command,
            "args" => args,
            "error" => message
          })

        persist_run(record, opts)
        {:error, "Executor #{executor} crashed: #{message}"}
    end
  end

  defp base_record(attrs, executor, cwd, project) do
    %{
      "id" => generate_run_id(),
      "executor" => executor,
      "task" =>
        Map.get(attrs, "task") || Map.get(attrs, :task) || Map.get(attrs, "prompt") ||
          Map.get(attrs, :prompt),
      "summary" => Map.get(attrs, "summary") || Map.get(attrs, :summary),
      "cwd" => cwd,
      "project" => project,
      "status" => "queued"
    }
  end

  defp persist_run(record, opts) do
    File.write!(runs_file(opts), Jason.encode!(record) <> "\n", [:append])
    Audit.append("executor.dispatch", record, opts)

    if is_binary(record["project"]) and record["project"] != "" do
      ProjectMemory.append_run(record["project"], record, opts)
    end
  end

  defp runs_file(opts), do: Path.join(Workspace.executors_dir(opts), @runs_file)

  defp executor_config(name, opts) do
    path = Path.join(Workspace.executors_dir(opts), "#{name}.json")

    config =
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end

    enabled = Map.get(config, "enabled", false) == true
    executable = Map.get(config, "command") || default_executable(name)
    prompt_mode = Map.get(config, "prompt_mode", "stdin")
    timeout = Map.get(config, "timeout", 300)
    args = Map.get(config, "args", [])

    %{
      name: name,
      configured: enabled,
      available: enabled and not is_nil(System.find_executable(executable)),
      executable: executable,
      prompt_mode: prompt_mode,
      timeout: timeout,
      args: if(is_list(args), do: Enum.map(args, &to_string/1), else: [])
    }
  end

  defp default_executable("codex_cli"), do: "codex"
  defp default_executable("claude_code_cli"), do: "claude"

  defp build_args(%{prompt_mode: "arg_append", args: args}, prompt), do: args ++ [prompt]
  defp build_args(%{args: args}, _prompt), do: args

  defp build_cmd_opts(%{prompt_mode: "stdin"}, prompt, cwd) do
    [stderr_to_stdout: true, cd: cwd, prompt_input: prompt]
  end

  defp build_cmd_opts(_config, _prompt, cwd) do
    [stderr_to_stdout: true, cd: cwd]
  end

  defp run_command(command, args, cmd_opts, timeout_seconds) do
    timeout_ms = max(timeout_seconds, 1) * 1000
    prompt = Keyword.get(cmd_opts, :prompt_input)
    system_opts = Keyword.delete(cmd_opts, :prompt_input)

    task =
      Task.async(fn ->
        if is_binary(prompt) do
          run_stdin_command(command, args, prompt, system_opts)
        else
          System.cmd(command, args, system_opts)
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp run_stdin_command(command, args, prompt, system_opts) do
    prompt_file = temp_prompt_file()

    try do
      File.write!(prompt_file, prompt)

      shell_args = [
        "-lc",
        "cat \"$NEX_AGENT_PROMPT_FILE\" | exec \"$NEX_AGENT_EXECUTABLE\" \"$@\"",
        "nex-agent-executor"
        | args
      ]

      env =
        [{"NEX_AGENT_PROMPT_FILE", prompt_file}, {"NEX_AGENT_EXECUTABLE", command}] ++
          Keyword.get(system_opts, :env, [])

      system_opts =
        system_opts
        |> Keyword.put(:env, env)

      System.cmd("sh", shell_args, system_opts)
    after
      File.rm(prompt_file)
    end
  end

  defp temp_prompt_file do
    Path.join(System.tmp_dir!(), "nex-agent-exec-#{System.unique_integer([:positive])}.txt")
  end

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  defp sanitize_output(output) when is_binary(output) do
    if String.valid?(output), do: output, else: Base.encode64(output)
  end

  defp sanitize_output(output), do: inspect(output)

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp generate_run_id do
    "exec_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
