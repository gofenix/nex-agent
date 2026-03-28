defmodule Nex.E2E.SkillRuntimeLiveHelpers do
  @moduledoc false

  alias Nex.Agent.Tool.Registry

  def setup_runtime! do
    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      {:ok, _pid} = Task.Supervisor.start_link(name: Nex.Agent.TaskSupervisor)
    end

    if Process.whereis(Registry) == nil do
      {:ok, _pid} = Registry.start_link(name: Registry)
    end
  end

  def setup_workspace! do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-skill-runtime-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")
    workspace
  end

  def provider_opts do
    [
      provider: :openai,
      model: System.get_env("SKILL_RUNTIME_LIVE_OPENAI_MODEL") || "gpt-4o",
      api_key: System.fetch_env!("OPENAI_API_KEY"),
      base_url: System.get_env("OPENAI_BASE_URL")
    ]
  end

  def missing_envs(keys) do
    Enum.filter(keys, fn key ->
      case System.get_env(key) do
        nil -> true
        "" -> true
        _ -> false
      end
    end)
  end
end

defmodule Nex.E2E.SkillRuntimeOpenAILiveE2ETest do
  use ExUnit.Case, async: false

  @moduletag :live_e2e

  alias Nex.Agent.{Runner, Session}
  alias Nex.E2E.SkillRuntimeLiveHelpers, as: Helpers

  setup_all do
    case Helpers.missing_envs(["OPENAI_API_KEY"]) do
      [] ->
        Helpers.setup_runtime!()
        :ok

      missing ->
        {:ok, skip: "missing live E2E env vars: #{Enum.join(missing, ", ")}"}
    end
  end

  test "openai can answer with a selected local runtime package" do
    workspace = Helpers.setup_workspace!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    package_dir = Path.join(workspace, "skills/rt__live_local_checklist")
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: live-local-checklist
      description: A distinctive local checklist for live SkillRuntime verification.
      execution_mode: knowledge
      version: 1
      ---

      Live local checklist:
      1. Verify scarlet widget status.
      2. Confirm blast radius.
      3. Notify the owner.
      """
    )

    assert {:ok, result, session} =
             Runner.run(
               Session.new("live-local-runtime"),
               "Use the live local checklist. Start your answer with LIVE_LOCAL_PACKAGE_OK and mention scarlet widget status.",
               Helpers.provider_opts() ++
                 [
                   workspace: workspace,
                   cwd: workspace,
                   skill_runtime: %{"enabled" => true},
                   skip_consolidation: true,
                   max_iterations: 4
                 ]
             )

    assert result =~ "LIVE_LOCAL_PACKAGE_OK"
    assert String.downcase(result) =~ "scarlet widget"

    assert get_in(session.metadata, ["skill_runtime", "selected_packages"])
           |> Enum.any?(fn pkg ->
             pkg["name"] == "live-local-checklist"
           end)
  end
end

defmodule Nex.E2E.SkillRuntimeGitHubLiveE2ETest do
  use ExUnit.Case, async: false

  @moduletag :live_e2e

  alias Nex.Agent.{Runner, Session}
  alias Nex.E2E.SkillRuntimeLiveHelpers, as: Helpers
  alias Nex.SkillRuntime

  setup_all do
    case Helpers.missing_envs(["OPENAI_API_KEY", "GH_TOKEN"]) do
      [] ->
        Helpers.setup_runtime!()
        :ok

      missing ->
        alt_missing =
          missing
          |> Enum.reject(&(&1 == "GH_TOKEN" and System.get_env("GITHUB_TOKEN")))

        if alt_missing == [] do
          Helpers.setup_runtime!()
          :ok
        else
          {:ok, skip: "missing live E2E env vars: #{Enum.join(alt_missing, ", ")}"}
        end
    end
  end

  test "openai can import and execute a real github runtime package" do
    repo = System.get_env("SKILL_RUNTIME_LIVE_REPO") || System.get_env("GITHUB_REPOSITORY")
    commit_sha = System.get_env("SKILL_RUNTIME_LIVE_COMMIT_SHA") || System.get_env("GITHUB_SHA")

    path =
      System.get_env("SKILL_RUNTIME_LIVE_PATH") ||
        "test/support/fixtures/skill_runtime/live_packages/live_echo_playbook"

    missing =
      [repo, commit_sha]
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {nil, 0} -> ["SKILL_RUNTIME_LIVE_REPO or GITHUB_REPOSITORY"]
        {"", 0} -> ["SKILL_RUNTIME_LIVE_REPO or GITHUB_REPOSITORY"]
        {nil, 1} -> ["SKILL_RUNTIME_LIVE_COMMIT_SHA or GITHUB_SHA"]
        {"", 1} -> ["SKILL_RUNTIME_LIVE_COMMIT_SHA or GITHUB_SHA"]
        _ -> []
      end)

    if missing != [] do
      IO.puts("Skipping GitHub live E2E: missing #{Enum.join(missing, ", ")}")
      assert true
    else
      workspace = Helpers.setup_workspace!()
      on_exit(fn -> File.rm_rf!(workspace) end)

      assert {:ok, package} =
               SkillRuntime.import(
                 %{
                   "source_id" => "live-echo-playbook",
                   "repo" => repo,
                   "commit_sha" => commit_sha,
                   "path" => path
                 },
                 workspace: workspace,
                 project_root: workspace,
                 skill_runtime: %{"enabled" => true}
               )

      assert package.name == "live-echo-playbook"

      assert {:ok, result, session} =
               Runner.run(
                 Session.new("live-remote-runtime"),
                 "Use the live-echo-playbook tool exactly once with task ping and then answer with the tool output prefixed by LIVE_REMOTE_SUMMARY.",
                 Helpers.provider_opts() ++
                   [
                     workspace: workspace,
                     cwd: workspace,
                     skill_runtime: %{"enabled" => true},
                     skip_consolidation: true,
                     max_iterations: 6
                   ]
               )

      assert Enum.any?(session.messages, fn
               %{
                 "role" => "tool",
                 "name" => "skill_run__live_echo_playbook",
                 "content" => content
               } ->
                 content =~ "LIVE_REMOTE_TOOL_OK:{\"task\":\"ping\"}"

               _ ->
                 false
             end)

      assert result =~ "LIVE_REMOTE_SUMMARY"
      assert result =~ "LIVE_REMOTE_TOOL_OK"
    end
  end
end
