defmodule Nex.SkillRuntimeTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session}
  alias Nex.Agent.Tool.Registry
  alias Nex.SkillRuntime

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-skill-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "search indexes local package skills and infers playbook mode", %{workspace: workspace} do
    package_dir = Path.join(workspace, "skills/rt__local_widget_playbook")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: local-widget-playbook
      description: Diagnose widget issues from logs
      entry_script: scripts/run.sh
      ---

      Inspect widget logs and produce a diagnosis.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho ok\n")

    assert {:ok, hits} =
             SkillRuntime.search("widget logs diagnosis",
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert [%{type: :local, package: package} | _] = hits
    assert package.execution_mode == "playbook"
    assert package.tool_name == "skill_run__local_widget_playbook"
  end

  test "trusted github catalog sync and import download a package directory", %{
    workspace: workspace
  } do
    skill_md = """
    ---
    name: remote-widget-playbook
    description: Remote widget diagnosis package
    entry_script: scripts/run.sh
    execution_mode: playbook
    ---

    Use this package when the widget breaks in production.
    """

    script = "#!/bin/sh\necho remote:$1\n"

    entry = %{
      "source_id" => "remote-widget-playbook",
      "repo" => "acme/skills",
      "commit_sha" => "abc123",
      "path" => "packages/remote-widget-playbook",
      "name" => "remote-widget-playbook",
      "description" => "Remote widget diagnosis package",
      "execution_mode" => "playbook",
      "entry_script" => "scripts/run.sh",
      "dependencies" => [],
      "required_keys" => [],
      "allowed_tools" => [],
      "tags" => ["widget", "ops"],
      "host_compat" => ["nex_agent"],
      "risk_level" => "low",
      "file_manifest" => %{
        "SKILL.md" => sha256(skill_md),
        "scripts/run.sh" => sha256(script)
      },
      "package_checksum" => sha256(skill_md <> script)
    }

    http_get = fake_http_get(skill_md, script, entry)

    assert {:ok, hits} =
             SkillRuntime.search("remote widget diagnosis",
               workspace: workspace,
               project_root: workspace,
               http_get: http_get,
               skill_runtime: %{
                 "enabled" => true,
                 "github_indexes" => [
                   %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
                 ]
               }
             )

    assert Enum.any?(
             hits,
             &(&1.type == :remote and &1.entry.source_id == "remote-widget-playbook")
           )

    assert {:ok, package} =
             SkillRuntime.import("remote-widget-playbook",
               workspace: workspace,
               project_root: workspace,
               http_get: http_get,
               skill_runtime: %{
                 "enabled" => true,
                 "github_indexes" => [
                   %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
                 ]
               }
             )

    assert package.execution_mode == "playbook"
    assert File.exists?(Path.join(package.root_path, "source.json"))
    assert File.exists?(Path.join(package.root_path, ".skill_id"))
    assert File.exists?(Path.join(package.root_path, "scripts/run.sh"))
  end

  test "runner exposes and executes ephemeral playbook tools", %{workspace: workspace} do
    package_dir = Path.join(workspace, "skills/rt__widget_ops")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: widget-ops
      description: Handle widget incidents
      execution_mode: playbook
      entry_script: scripts/run.sh
      parameters:
        type: object
        properties:
          task:
            type: string
      ---

      Use this skill when the widget is down and you need the incident playbook.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho playbook:$1\n")

    parent = self()
    Process.put(:skill_runtime_llm_calls, 0)

    llm_client = fn _messages, opts ->
      send(parent, {:tools, Keyword.get(opts, :tools, [])})

      case Process.get(:skill_runtime_llm_calls, 0) do
        0 ->
          Process.put(:skill_runtime_llm_calls, 1)

          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "skill_run",
                 function: %{
                   name: "skill_run__widget_ops",
                   arguments: %{"task" => "restore service"}
                 }
               }
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "done", session} =
             Runner.run(Session.new("skill-runtime"), "run the widget incident playbook",
               llm_client: llm_client,
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    assert_receive {:tools, tools}
    assert Enum.any?(tools, &(&1["name"] == "skill_run__widget_ops"))

    tool_message =
      Enum.find(session.messages, fn message ->
        message["role"] == "tool" and message["name"] == "skill_run__widget_ops"
      end)

    assert tool_message["content"] =~ "playbook:{\"task\":\"restore service\"}"

    runs_dir = Path.join(workspace, "skill_runtime/runs")
    assert [_ | _] = Path.wildcard(Path.join(runs_dir, "*.jsonl"))
  end

  defp fake_http_get(skill_md, script, entry) do
    fn url, _opts ->
      body =
        cond do
          String.contains?(url, "/repos/org/index/contents/index.json?ref=main") ->
            Jason.encode!(%{"content" => Base.encode64(Jason.encode!(%{"skills" => [entry]}))})

          String.contains?(
            url,
            "/repos/acme/skills/contents/packages/remote-widget-playbook?ref=abc123"
          ) ->
            Jason.encode!([
              %{
                "type" => "file",
                "name" => "SKILL.md",
                "path" => "packages/remote-widget-playbook/SKILL.md",
                "download_url" => "https://download.example/skill_md"
              },
              %{
                "type" => "dir",
                "name" => "scripts",
                "path" => "packages/remote-widget-playbook/scripts"
              }
            ])

          String.contains?(
            url,
            "/repos/acme/skills/contents/packages/remote-widget-playbook/scripts?ref=abc123"
          ) ->
            Jason.encode!([
              %{
                "type" => "file",
                "name" => "run.sh",
                "path" => "packages/remote-widget-playbook/scripts/run.sh",
                "download_url" => "https://download.example/run_sh"
              }
            ])

          url == "https://download.example/skill_md" ->
            skill_md

          url == "https://download.example/run_sh" ->
            script

          true ->
            ""
        end

      {:ok, %{status: 200, body: body}}
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
