defmodule Nex.Agent.OpencodeRunToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.OpencodeRun

  setup do
    root =
      Path.join(System.tmp_dir!(), "nex-agent-opencode-run-#{System.unique_integer([:positive])}")

    work_dir = Path.join(root, "repo")
    fake_bin = Path.join(root, "bin")
    workspace = Path.join(root, "workspace")

    File.mkdir_p!(work_dir)
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(workspace)

    System.cmd("git", ["init"], cd: work_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: work_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: work_dir)
    File.write!(Path.join(work_dir, "README.md"), "# Nex Agent\n")
    System.cmd("git", ["add", "README.md"], cd: work_dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: work_dir, stderr_to_stdout: true)

    fake_opencode = Path.join(fake_bin, "opencode")

    File.write!(fake_opencode, """
    #!/bin/sh
    if read unexpected_stdin; then
      echo "stdin was not closed: $unexpected_stdin"
      exit 2
    fi
    printf '%s\\n' "$@" > opencode-args.txt
    echo '{"type":"started","message":"fake opencode started"}'
    echo '# README 日本語版' > README.jp.md
    echo '{"type":"completed","message":"fake opencode completed"}'
    exit 0
    """)

    File.chmod!(fake_opencode, 0o755)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, work_dir: work_dir, workspace: workspace, fake_bin: fake_bin}
  end

  test "runs opencode with an observable prompt, log, metadata, and diff summary", %{
    work_dir: work_dir,
    workspace: workspace,
    fake_bin: fake_bin
  } do
    path = fake_bin <> ":" <> System.get_env("PATH", "")

    assert {:ok, json} =
             OpencodeRun.execute(
               %{
                 "work_dir" => work_dir,
                 "branch" => "codex/github-issue-12-test",
                 "repo" => "gofenix/nex-agent",
                 "issue_number" => 12,
                 "issue_title" => "add jp readme",
                 "issue_body" => "add jp",
                 "model" => "opencode/test-model",
                 "timeout" => 5
               },
               %{workspace: workspace, model: "outer/model", env: %{"PATH" => path}}
             )

    assert {:ok, result} = Jason.decode(json)
    assert result["status"] == "ok"
    assert result["exit_code"] == 0
    assert result["work_dir"] == work_dir
    assert result["branch"] == "codex/github-issue-12-test"
    assert result["model"] == "opencode/test-model"
    assert result["outer_model"] == "outer/model"
    assert result["command"] =~ "opencode run"
    assert result["command"] =~ "--format json"
    assert result["command"] =~ "--print-logs"
    assert result["git_status"] =~ "README.jp.md"

    assert File.exists?(result["prompt_path"])
    assert File.exists?(result["log_path"])
    assert File.exists?(result["metadata_path"])

    assert File.read!(result["prompt_path"]) =~ "Resolve GitHub Issue #12"
    assert File.read!(result["prompt_path"]) =~ "Do not commit, push, or create a pull request"
    assert File.read!(result["log_path"]) =~ "fake opencode started"

    assert {:ok, metadata} = result["metadata_path"] |> File.read!() |> Jason.decode()
    assert metadata["repo"] == "gofenix/nex-agent"
    assert metadata["issue_number"] == 12
    assert metadata["command"] == result["command"]

    opencode_args = File.read!(Path.join(work_dir, "opencode-args.txt"))
    assert opencode_args =~ "--model"
    assert opencode_args =~ "opencode/test-model"
  end

  test "uses the GitHub Project metadata model when the tool args omit model", %{
    work_dir: work_dir,
    workspace: workspace,
    fake_bin: fake_bin
  } do
    path = fake_bin <> ":" <> System.get_env("PATH", "")

    assert {:ok, json} =
             OpencodeRun.execute(
               %{
                 "work_dir" => work_dir,
                 "branch" => "codex/github-issue-12-metadata-model",
                 "repo" => "gofenix/nex-agent",
                 "issue_number" => 12,
                 "issue_title" => "add jp readme",
                 "timeout" => 5
               },
               %{
                 workspace: workspace,
                 env: %{"PATH" => path},
                 metadata: %{"opencode_model" => "opencode/metadata-model"}
               }
             )

    assert {:ok, result} = Jason.decode(json)
    assert result["model"] == "opencode/metadata-model"
    assert File.read!(Path.join(work_dir, "opencode-args.txt")) =~ "opencode/metadata-model"
  end

  test "uses configured GitHub Project model when args and metadata omit model", %{
    work_dir: work_dir,
    workspace: workspace,
    fake_bin: fake_bin
  } do
    previous_config_path = Application.get_env(:nex_agent, :config_path)
    config_path = Path.join(workspace, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "github_project" => %{"opencode_model" => "opencode/config-model"}
      })
    )

    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      if previous_config_path do
        Application.put_env(:nex_agent, :config_path, previous_config_path)
      else
        Application.delete_env(:nex_agent, :config_path)
      end
    end)

    path = fake_bin <> ":" <> System.get_env("PATH", "")

    assert {:ok, json} =
             OpencodeRun.execute(
               %{
                 "work_dir" => work_dir,
                 "branch" => "codex/github-issue-12-config-model",
                 "repo" => "gofenix/nex-agent",
                 "issue_number" => 12,
                 "issue_title" => "add jp readme",
                 "timeout" => 5
               },
               %{workspace: workspace, env: %{"PATH" => path}}
             )

    assert {:ok, result} = Jason.decode(json)
    assert result["model"] == "opencode/config-model"
    assert File.read!(Path.join(work_dir, "opencode-args.txt")) =~ "opencode/config-model"
  end

  test "requires an explicit opencode model", %{
    work_dir: work_dir,
    workspace: workspace,
    fake_bin: fake_bin
  } do
    previous_model = System.get_env("OPENCODE_MODEL")
    previous_config_path = Application.get_env(:nex_agent, :config_path)
    System.delete_env("OPENCODE_MODEL")
    Application.put_env(:nex_agent, :config_path, Path.join(workspace, "missing-config.json"))

    on_exit(fn ->
      if previous_model do
        System.put_env("OPENCODE_MODEL", previous_model)
      end

      if previous_config_path do
        Application.put_env(:nex_agent, :config_path, previous_config_path)
      else
        Application.delete_env(:nex_agent, :config_path)
      end
    end)

    path = fake_bin <> ":" <> System.get_env("PATH", "")

    assert {:error, message} =
             OpencodeRun.execute(
               %{
                 "work_dir" => work_dir,
                 "branch" => "codex/github-issue-12-no-model",
                 "repo" => "gofenix/nex-agent",
                 "issue_number" => 12,
                 "issue_title" => "add jp readme",
                 "timeout" => 5
               },
               %{workspace: workspace, env: %{"PATH" => path}}
             )

    assert message =~ "opencode model is required"
  end
end
