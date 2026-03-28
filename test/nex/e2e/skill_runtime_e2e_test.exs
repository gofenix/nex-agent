defmodule Nex.E2E.SkillRuntimeE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias Nex.Agent.{Runner, Session}
  alias Nex.Agent.Tool.Registry

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-skill-runtime-e2e-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")

    Application.put_env(:nex_agent, :workspace_path, workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "runner can discover inspect and execute a local runtime package end-to-end", %{
    workspace: workspace
  } do
    package_dir = Path.join(workspace, "skills/rt__local_widget_ops")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: local-widget-ops
      description: Restore the local widget service.
      execution_mode: playbook
      entry_script: scripts/run.sh
      parameters:
        type: object
        properties:
          task:
            type: string
      ---

      Use this playbook when the widget service is degraded and needs a standard recovery path.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho local:$1\n")

    parent = self()

    llm_client = fn messages, opts ->
      send(parent, {:local_runtime_call, messages, Keyword.get(opts, :tools, [])})

      cond do
        is_nil(tool_result(messages, "skill_discover")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "discover_local",
                 function: %{
                   name: "skill_discover",
                   arguments: %{"query" => "widget service recovery"}
                 }
               }
             ]
           }}

        is_nil(tool_result(messages, "skill_get")) ->
          discover = tool_result(messages, "skill_discover")
          skill_id = discover["hits"] |> List.first() |> Map.fetch!("skill_id")

          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "get_local",
                 function: %{name: "skill_get", arguments: %{"skill_id" => skill_id}}
               }
             ]
           }}

        is_nil(tool_result(messages, "skill_run__local_widget_ops")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "run_local",
                 function: %{
                   name: "skill_run__local_widget_ops",
                   arguments: %{"task" => "restore service"}
                 }
               }
             ]
           }}

        true ->
          {:ok, %{content: "local runtime complete", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "local runtime complete", session} =
             Runner.run(Session.new("e2e-local-runtime"), "restore the widget service",
               llm_client: llm_client,
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    assert_receive {:local_runtime_call, first_messages, first_tools}

    assert system_content(first_messages) =~ "[Skill Package]"
    assert system_content(first_messages) =~ "Name: local-widget-ops"

    assert system_content(first_messages) =~
             "Use this playbook when the widget service is degraded"

    assert Enum.any?(first_tools, &(&1["name"] == "skill_run__local_widget_ops"))

    assert Enum.any?(session.messages, &tool_message?(&1, "skill_discover"))
    assert Enum.any?(session.messages, &tool_message?(&1, "skill_get"))

    assert Enum.any?(session.messages, fn
             %{"role" => "tool", "name" => "skill_run__local_widget_ops", "content" => content} ->
               content =~ "local:{\"task\":\"restore service\"}"

             _ ->
               false
           end)

    assert [_ | _] = Path.wildcard(Path.join(workspace, "skill_runtime/runs/*.jsonl"))

    assert get_in(session.metadata, ["skill_runtime", "selected_packages"])
           |> Enum.any?(fn pkg ->
             pkg["name"] == "local-widget-ops"
           end)
  end

  test "runner can discover import and execute a trusted github package end-to-end", %{
    workspace: workspace
  } do
    skill_md = """
    ---
    name: remote-widget-playbook
    description: Remote widget diagnosis package
    execution_mode: playbook
    entry_script: scripts/run.sh
    parameters:
      type: object
      properties:
        task:
          type: string
    ---

    Use this package when the remote widget breaks in production.
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
    parent = self()

    llm_client = fn messages, opts ->
      send(parent, {:remote_runtime_call, messages, Keyword.get(opts, :tools, [])})

      cond do
        is_nil(tool_result(messages, "skill_discover")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "discover_remote",
                 function: %{
                   name: "skill_discover",
                   arguments: %{"query" => "remote widget diagnosis"}
                 }
               }
             ]
           }}

        is_nil(tool_result(messages, "skill_import")) ->
          discover = tool_result(messages, "skill_discover")

          source_id =
            discover["hits"] |> Enum.find(&(&1["type"] == "remote")) |> Map.fetch!("source_id")

          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "import_remote",
                 function: %{name: "skill_import", arguments: %{"source_id" => source_id}}
               }
             ]
           }}

        is_nil(tool_result(messages, "skill_run__remote_widget_playbook")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "run_remote",
                 function: %{
                   name: "skill_run__remote_widget_playbook",
                   arguments: %{"task" => "inspect service"}
                 }
               }
             ]
           }}

        true ->
          {:ok, %{content: "remote runtime complete", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "remote runtime complete", session} =
             Runner.run(Session.new("e2e-remote-runtime"), "handle the remote widget diagnosis",
               llm_client: llm_client,
               workspace: workspace,
               cwd: workspace,
               http_get: http_get,
               skill_runtime: %{
                 "enabled" => true,
                 "github_indexes" => [
                   %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
                 ]
               },
               skip_consolidation: true
             )

    assert_receive {:remote_runtime_call, first_messages, first_tools}

    assert system_content(first_messages) =~ "skill_discover"
    assert Enum.any?(first_tools, &(&1["name"] == "skill_import"))
    assert Enum.any?(session.messages, &tool_message?(&1, "skill_import"))

    assert Enum.any?(session.messages, fn
             %{
               "role" => "tool",
               "name" => "skill_run__remote_widget_playbook",
               "content" => content
             } ->
               content =~ "remote:{\"task\":\"inspect service\"}"

             _ ->
               false
           end)

    assert File.dir?(Path.join(workspace, "skills/gh__remote_widget_playbook"))
    assert [_ | _] = Path.wildcard(Path.join(workspace, "skill_runtime/runs/*.jsonl"))
  end

  test "skill_capture persists a local knowledge package that the next run can discover and inspect",
       %{workspace: workspace} do
    capture_llm = fn messages, _opts ->
      cond do
        is_nil(tool_result(messages, "skill_capture")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "capture_skill",
                 function: %{
                   name: "skill_capture",
                   arguments: %{
                     "name" => "incident-checklist",
                     "description" => "Checklist for recurring incident response",
                     "content" => "Check logs, confirm blast radius, and notify the owner."
                   }
                 }
               }
             ]
           }}

        true ->
          {:ok, %{content: "captured", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "captured", _session} =
             Runner.run(Session.new("capture-runtime-skill"), "save this as a reusable skill",
               llm_client: capture_llm,
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    package_dir = Path.join(workspace, "skills/rt__incident_checklist")
    assert File.exists?(Path.join(package_dir, "SKILL.md"))
    assert File.exists?(Path.join(package_dir, ".skill_id"))
    assert File.exists?(Path.join(package_dir, "source.json"))

    parent = self()

    use_llm = fn messages, opts ->
      send(parent, {:captured_runtime_call, messages, Keyword.get(opts, :tools, [])})

      cond do
        is_nil(tool_result(messages, "skill_discover")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "discover_captured",
                 function: %{
                   name: "skill_discover",
                   arguments: %{"query" => "incident checklist"}
                 }
               }
             ]
           }}

        is_nil(tool_result(messages, "skill_get")) ->
          discover = tool_result(messages, "skill_discover")
          skill_id = discover["hits"] |> List.first() |> Map.fetch!("skill_id")

          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "get_captured",
                 function: %{name: "skill_get", arguments: %{"skill_id" => skill_id}}
               }
             ]
           }}

        true ->
          {:ok, %{content: "used captured skill", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "used captured skill", session} =
             Runner.run(
               Session.new("use-captured-runtime-skill"),
               "follow the incident checklist",
               llm_client: use_llm,
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    assert_receive {:captured_runtime_call, first_messages, _tools}
    assert system_content(first_messages) =~ "Name: incident-checklist"

    assert system_content(first_messages) =~
             "Check logs, confirm blast radius, and notify the owner."

    assert Enum.any?(session.messages, &tool_message?(&1, "skill_get"))
    assert [_ | _] = Path.wildcard(Path.join(workspace, "skill_runtime/runs/*.jsonl"))
  end

  test "runtime disabled leaves runner as a no-op for skill runtime and skill tools return clear errors",
       %{workspace: workspace} do
    legacy_dir = Path.join(workspace, "skills/legacy-guide")
    File.mkdir_p!(legacy_dir)

    File.write!(
      Path.join(legacy_dir, "SKILL.md"),
      """
      ---
      name: legacy-guide
      description: Old markdown skill that should not be migrated when runtime is disabled.
      ---

      Legacy content.
      """
    )

    parent = self()

    llm_client = fn messages, opts ->
      send(parent, {:disabled_runtime_call, messages, Keyword.get(opts, :tools, [])})

      cond do
        is_nil(tool_result(messages, "skill_discover")) ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "discover_disabled",
                 function: %{name: "skill_discover", arguments: %{"query" => "legacy guide"}}
               }
             ]
           }}

        true ->
          {:ok, %{content: "runtime disabled", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "runtime disabled", session} =
             Runner.run(Session.new("runtime-disabled"), "check skill discovery",
               llm_client: llm_client,
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => false},
               skip_consolidation: true
             )

    assert_receive {:disabled_runtime_call, first_messages, first_tools}
    refute system_content(first_messages) =~ "[Skill Package]"
    refute Enum.any?(first_tools, &String.starts_with?(&1["name"], "skill_run__"))

    assert Enum.any?(session.messages, fn
             %{"role" => "tool", "name" => "skill_discover", "content" => content} ->
               content =~ "Error: SkillRuntime is disabled in config"

             _ ->
               false
           end)

    assert File.exists?(Path.join(legacy_dir, "SKILL.md"))
    refute File.exists?(Path.join(workspace, "skills/rt__legacy_guide"))
    refute File.exists?(Path.join(workspace, "skill_runtime/index/migration_report.jsonl"))
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

  defp system_content(messages) do
    messages
    |> Enum.find(&(&1["role"] == "system"))
    |> Map.fetch!("content")
  end

  defp tool_result(messages, tool_name) do
    case Enum.find(messages, fn
           %{"role" => "tool", "name" => ^tool_name} -> true
           _ -> false
         end) do
      nil ->
        nil

      %{"content" => content} ->
        case Jason.decode(content) do
          {:ok, decoded} -> decoded
          _ -> content
        end
    end
  end

  defp tool_message?(%{"role" => "tool", "name" => tool_name}, tool_name), do: true
  defp tool_message?(_, _tool_name), do: false

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
