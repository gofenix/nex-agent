defmodule Nex.Agent.Tool.OpencodeRun do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Config

  require Logger

  @idle_log_interval_ms 60_000

  def name, do: "opencode_run"
  def description, do: "Run opencode from a disposable checkout with observable logs"
  def category, do: :base

  def definition do
    %{
      name: "opencode_run",
      description:
        "Run opencode from a disposable checkout. Records prompt, command metadata, stdout/stderr log, exit code, and git diff summary.",
      parameters: %{
        type: "object",
        properties: %{
          work_dir: %{type: "string", description: "Disposable checkout directory"},
          branch: %{
            type: "string",
            description: "Branch to switch/create before running opencode"
          },
          repo: %{type: "string", description: "GitHub repo, e.g. gofenix/nex-agent"},
          issue_number: %{type: "integer", description: "GitHub issue number"},
          issue_title: %{type: "string", description: "GitHub issue title"},
          issue_body: %{type: "string", description: "GitHub issue body"},
          model: %{
            type: "string",
            description: "Opencode model in provider/model format"
          },
          timeout: %{type: "number", description: "Timeout in seconds", default: 1800}
        },
        required: ["work_dir", "branch", "repo", "issue_number", "issue_title"]
      }
    }
  end

  def execute(args, ctx) when is_map(args) do
    with {:ok, work_dir} <- required_string(args, "work_dir"),
         :ok <- validate_work_dir(work_dir),
         {:ok, branch} <- required_string(args, "branch"),
         {:ok, repo} <- required_string(args, "repo"),
         {:ok, issue_number} <- required_issue_number(args),
         {:ok, issue_title} <- required_string(args, "issue_title"),
         {:ok, opencode} <- find_opencode(ctx),
         {:ok, run_paths} <- prepare_run_paths(args, ctx, issue_number),
         :ok <- write_prompt(run_paths.prompt_path, args, repo, issue_number, issue_title),
         :ok <- git_switch(work_dir, branch),
         {:ok, model} <- effective_model(args, ctx) do
      run_opencode(
        opencode,
        work_dir,
        branch,
        repo,
        issue_number,
        issue_title,
        args,
        ctx,
        run_paths,
        model
      )
    end
  end

  def execute(_args, _ctx), do: {:error, "opencode_run arguments must be an object"}

  defp run_opencode(
         opencode,
         work_dir,
         branch,
         repo,
         issue_number,
         issue_title,
         args,
         ctx,
         run_paths,
         model
       ) do
    timeout_ms = normalize_timeout_ms(Map.get(args, "timeout", Map.get(ctx, :timeout, 1800)))
    prompt = File.read!(run_paths.prompt_path)
    argv = opencode_args(prompt, issue_title, model)
    command = command_preview(opencode, argv)
    env = env_list(ctx)

    metadata =
      base_metadata(args, ctx, %{
        "branch" => branch,
        "command" => command,
        "issue_number" => issue_number,
        "issue_title" => issue_title,
        "log_path" => run_paths.log_path,
        "metadata_path" => run_paths.metadata_path,
        "model" => model,
        "outer_model" => Map.get(ctx, :model),
        "prompt_path" => run_paths.prompt_path,
        "repo" => repo,
        "run_id" => run_paths.run_id,
        "started_at" => now_iso(),
        "timeout_seconds" => div(timeout_ms, 1000),
        "work_dir" => work_dir
      })

    write_json!(run_paths.metadata_path, metadata)

    Logger.info("[OpencodeRun] start run_id=#{run_paths.run_id} model=#{model} cwd=#{work_dir}")

    Logger.info("[OpencodeRun] prompt=#{run_paths.prompt_path} log=#{run_paths.log_path}")

    {exit_status, duration_ms} =
      timed(fn ->
        stream_command(opencode, argv, work_dir, env, run_paths.log_path, timeout_ms)
      end)

    git_status = git_output(work_dir, ["status", "--short"])
    git_diff_stat = git_output(work_dir, ["diff", "--stat"])

    result =
      metadata
      |> Map.merge(%{
        "duration_ms" => duration_ms,
        "exit_code" => exit_status,
        "finished_at" => now_iso(),
        "git_status" => git_status,
        "git_diff_stat" => git_diff_stat,
        "status" => if(exit_status == 0, do: "ok", else: "error")
      })

    write_json!(run_paths.metadata_path, result)

    if exit_status == 0 do
      {:ok, Jason.encode!(result, pretty: true)}
    else
      {:error, Jason.encode!(result, pretty: true)}
    end
  end

  defp opencode_args(prompt, issue_title, model) do
    [
      "run",
      "--format",
      "json",
      "--print-logs",
      "--model",
      model,
      "--dangerously-skip-permissions",
      "--title",
      issue_title,
      prompt
    ]
  end

  defp stream_command(executable, argv, work_dir, env, log_path, timeout_ms) do
    File.write!(log_path, "")

    {spawn_executable, spawn_args} = stdin_from_dev_null(executable, argv)

    port =
      Port.open(
        {:spawn_executable, spawn_executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, spawn_args},
          {:cd, work_dir},
          {:env, env}
        ]
      )

    now = System.monotonic_time(:millisecond)
    collect_port(port, log_path, now + timeout_ms, now)
  end

  defp collect_port(port, log_path, deadline_ms, last_activity_ms) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now, 0)
    wait_ms = min(remaining, @idle_log_interval_ms)

    receive do
      {^port, {:data, data}} ->
        text = safe_text(data)
        File.write!(log_path, text, [:append])
        log_opencode_chunk(text)
        collect_port(port, log_path, deadline_ms, System.monotonic_time(:millisecond))

      {^port, {:exit_status, status}} ->
        status
    after
      wait_ms ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          File.write!(log_path, "\n[OpencodeRun] timed out\n", [:append])
          Port.close(port)
          124
        else
          idle_seconds =
            div(System.monotonic_time(:millisecond) - last_activity_ms, 1000)

          line = "\n[OpencodeRun] still running; no output for #{idle_seconds}s\n"
          File.write!(log_path, line, [:append])
          Logger.info(String.trim(line))
          collect_port(port, log_path, deadline_ms, last_activity_ms)
        end
    end
  end

  defp stdin_from_dev_null(executable, argv) do
    shell = System.find_executable("sh") || "/bin/sh"
    {shell, ["-c", "exec \"$@\" < /dev/null", "opencode-run", executable | argv]}
  end

  defp log_opencode_chunk(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.take(-8)
    |> Enum.each(fn line ->
      Logger.info("[OpencodeRun] #{String.slice(line, 0, 500)}")
    end)
  end

  defp write_prompt(path, args, repo, issue_number, issue_title) do
    issue_body = Map.get(args, "issue_body") || Map.get(args, :issue_body) || ""

    prompt = """
    Resolve GitHub Issue ##{issue_number} on #{repo}: #{issue_title}

    #{issue_body}

    Make the smallest local code/doc changes required.
    Run the narrowest useful verification.
    Do not commit, push, or create a pull request.
    Stop after local changes and verification.
    """

    File.write!(path, prompt)
    :ok
  end

  defp prepare_run_paths(args, ctx, issue_number) do
    workspace = Map.get(ctx, :workspace) || Path.join(required_work_dir!(args), ".nex")

    run_id =
      "github-issue-#{issue_number}-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"

    dir = Path.join([workspace, "tasks", "opencode_runs", run_id])
    File.mkdir_p!(dir)

    {:ok,
     %{
       run_id: run_id,
       prompt_path: Path.join(dir, "prompt.txt"),
       log_path: Path.join(dir, "opencode.log"),
       metadata_path: Path.join(dir, "metadata.json")
     }}
  end

  defp base_metadata(args, ctx, metadata) do
    Map.merge(metadata, %{
      "ctx_channel" => Map.get(ctx, :channel),
      "ctx_chat_id" => Map.get(ctx, :chat_id),
      "metadata" => Map.get(ctx, :metadata, %{}),
      "requested_args" =>
        Map.take(args, [
          "branch",
          "issue_number",
          "issue_title",
          "model",
          "repo",
          "timeout",
          "work_dir"
        ])
    })
  end

  defp git_switch(work_dir, branch) do
    case System.cmd("git", ["switch", "-C", branch], cd: work_dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> {:error, "git switch failed:\n#{output}"}
    end
  end

  defp git_output(work_dir, args) do
    case System.cmd("git", args, cd: work_dir, stderr_to_stdout: true) do
      {output, _} -> safe_text(output)
    end
  end

  defp find_opencode(ctx) do
    path = get_in(ctx, [:env, "PATH"]) || System.get_env("PATH", "")

    case find_on_path("opencode", path) || System.find_executable("opencode") do
      nil -> {:error, "opencode executable not found on PATH"}
      executable -> {:ok, executable}
    end
  end

  defp find_on_path(command, path) when is_binary(path) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, command))
    |> Enum.find(&File.exists?/1)
  end

  defp effective_model(args, ctx) do
    metadata = Map.get(ctx, :metadata, %{})

    model =
      present(Map.get(args, "model") || Map.get(args, :model)) ||
        present(Map.get(metadata, "opencode_model") || Map.get(metadata, :opencode_model)) ||
        present(Config.load() |> Config.github_project() |> Map.get("opencode_model")) ||
        present(System.get_env("OPENCODE_MODEL"))

    case model do
      nil ->
        {:error,
         "opencode model is required. Set github_project.opencode_model or pass model to opencode_run."}

      value ->
        {:ok, value}
    end
  end

  defp env_list(ctx) do
    ctx
    |> Map.get(:env, %{})
    |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(to_string(value))} end)
  end

  defp validate_work_dir(work_dir) do
    cond do
      not File.dir?(work_dir) ->
        {:error, "work_dir does not exist: #{work_dir}"}

      String.starts_with?(work_dir, "/Users/fenix/github/") or
          String.starts_with?(work_dir, "/Users/fenix/repos/") ->
        {:error, "refusing to run opencode in long-lived checkout: #{work_dir}"}

      true ->
        :ok
    end
  end

  defp required_string(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp required_issue_number(args) do
    case Map.get(args, "issue_number") || Map.get(args, :issue_number) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value, "issue_number")
      _ -> {:error, "issue_number is required"}
    end
  end

  defp parse_positive_integer(value, key) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp required_work_dir!(args) do
    Map.get(args, "work_dir") || Map.get(args, :work_dir) || File.cwd!()
  end

  defp write_json!(path, data), do: File.write!(path, Jason.encode!(data, pretty: true))

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp command_preview(executable, argv) do
    ([Path.basename(executable)] ++ argv)
    |> Enum.map(&shell_quote/1)
    |> Enum.join(" ")
  end

  defp shell_quote(value) do
    value = to_string(value)

    if Regex.match?(~r|^[A-Za-z0-9_@%+=:,./-]+$|, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp normalize_timeout_ms(timeout) when is_integer(timeout) and timeout > 0, do: timeout * 1000

  defp normalize_timeout_ms(timeout) when is_float(timeout) and timeout > 0,
    do: trunc(timeout * 1000)

  defp normalize_timeout_ms(_), do: 1_800_000

  defp safe_text(output) when is_binary(output) do
    if String.valid?(output), do: output, else: Base.encode64(output)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
