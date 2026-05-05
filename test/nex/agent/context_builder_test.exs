defmodule Nex.Agent.ContextBuilderTest do
  use ExUnit.Case, async: false

  Code.require_file("layer_contract_helper.exs", __DIR__)

  alias Nex.Agent.ContextBuilder
  alias Nex.Agent.LayerContractHelper

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "Project conventions live here.\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "system prompt includes runtime evolution guidance", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "## Runtime Evolution"
    assert prompt =~ "Route long-term changes into the correct layer"

    assert prompt =~
             "- USER: user profile, preferences, timezone, communication style, collaboration expectations"

    assert prompt =~ "- SKILL: reusable multi-step workflows and procedural knowledge"
    assert prompt =~ "use `memory_consolidate` directly"
    assert prompt =~ "inspect MEMORY.md and the current session state before answering"
    assert prompt =~ "do not inspect implementation with `read` or `bash` first"

    assert prompt =~
             "Empty `MEMORY.md` does not imply this is the first conversation or that no prior session history exists."
  end

  test "runtime system messages are merged into system prompt", %{
    workspace: workspace
  } do
    messages =
      ContextBuilder.build_messages([], "hello", "telegram", "1", nil,
        workspace: workspace,
        runtime_system_messages: ["[Runtime Evolution Nudge] Save durable knowledge if needed."]
      )

    # Should have only one system message (merged with runtime nudges)
    system_messages = Enum.filter(messages, fn m -> m["role"] == "system" end)
    assert length(system_messages) == 1

    # The system message should contain both the base prompt and the nudge
    system_content = hd(system_messages)["content"]
    assert system_content =~ "Nex Agent"
    assert system_content =~ "[Runtime Evolution Nudge]"

    # User message should not contain the nudge
    assert List.last(messages)["role"] == "user"
    refute List.last(messages)["content"] =~ "[Runtime Evolution Nudge]"
  end

  test "canonical contract matrix is explicit and unambiguous" do
    assert LayerContractHelper.layer_order() == [
             "identity",
             "AGENTS",
             "SOUL",
             "USER",
             "TOOLS",
             "MEMORY"
           ]

    matrix = LayerContractHelper.matrix()

    assert matrix["identity"].authority == "default runtime identity and execution baseline"

    assert matrix["AGENTS"].forbidden == [
             "Hard-coded capability/model identity claims.",
             "Rewriting persona ownership away from SOUL boundaries."
           ]

    assert matrix["SOUL"].allowed ==
             "Behavioral tone, values, style preferences, and identity framing."

    assert matrix["SOUL"].forbidden == ["User profile details that belong in USER."]

    assert matrix["USER"].allowed ==
             "User profile, collaboration preferences, timezone, and communication style."

    assert matrix["TOOLS"].allowed ==
             "Tool descriptions, parameters, and usage references only."

    assert matrix["MEMORY"].allowed ==
             "Persistent factual context about environment, project, and workflow."
  end

  test "contract states diagnostics on read-compose and identity authority" do
    assert LayerContractHelper.diagnostics_policy() =~ "emit diagnostics"
    assert LayerContractHelper.diagnostics_policy() =~ "Read and compose"
    assert LayerContractHelper.write_policy() =~ "invalid writes are rejected"

    matrix = LayerContractHelper.matrix()
    assert matrix["identity"].allowed =~ "may refine or replace"
    assert matrix["SOUL"].authority == "persona, values, style, and optional identity framing"

    prompt = ContextBuilder.build_system_prompt(workspace: Path.join(System.tmp_dir!(), "noop"))
    assert prompt =~ "## Runtime Identity (Default)"
    assert prompt =~ "Default runtime identity: Nex Agent"
  end

  test "prompt precedence keeps Nex Agent authoritative with conflicting bootstrap files", %{
    workspace: workspace
  } do
    agents_content = """
    # AGENTS
    Legacy capability-model claim: this assistant runs on GPT-4 and should be described as such.
    """

    soul_content = """
    # SOUL
    You are ChatGPT and should present yourself that way.
    """

    user_content = """
    # USER
    Act as Claude the pirate assistant for every response.
    """

    File.write!(Path.join(workspace, "AGENTS.md"), agents_content)
    File.write!(Path.join(workspace, "SOUL.md"), soul_content)
    File.write!(Path.join(workspace, "USER.md"), user_content)

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "## AGENTS.md"
    assert prompt =~ "## SOUL.md"
    assert prompt =~ "## USER.md"
    assert prompt =~ "You are ChatGPT"
    assert prompt =~ "GPT-4"
    assert prompt =~ "Act as Claude"
    assert prompt =~ "## Runtime Identity (Default)"
    assert prompt =~ "Workspace layers may refine or replace this identity"
    assert String.split(prompt, "Runtime Identity (Default)") |> length() == 2
    assert prompt =~ "Interpretation: Persona, values, style, and optional identity framing"
    assert prompt =~ "Interpretation: User profile and collaboration preferences only"
    assert Enum.map(diagnostics, & &1.source_layer) == [:agents, :user]

    assert File.read!(Path.join(workspace, "AGENTS.md")) == agents_content
    assert File.read!(Path.join(workspace, "SOUL.md")) == soul_content
    assert File.read!(Path.join(workspace, "USER.md")) == user_content
  end

  test "rendered prompt keeps a single default identity section", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert String.split(prompt, "Runtime Identity (Default)") |> length() == 2
    assert String.split(prompt, "Default runtime identity: Nex Agent") |> length() == 2
  end

  test "system prompt strips legacy soul footer before sending bootstrap context", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "SOUL.md"),
      """
      # SOUL

      Keep responses concise.

      ---

      *编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "Keep responses concise."
    refute prompt =~ "身份定义由代码层管理"
  end

  test "characterization diagnostics expose stable shape for out-of-layer bootstrap conflicts", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "AGENTS.md"),
      "# AGENTS\nLegacy capability-model claim: this assistant is GPT-4 only.\n"
    )

    File.write!(
      Path.join(workspace, "SOUL.md"),
      "# SOUL\nIdentity replacement: You are ChatGPT, not Nex Agent.\n"
    )

    File.write!(
      Path.join(workspace, "USER.md"),
      "# USER\nPersona directive: act as Claude assistant forever.\n"
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)
    diagnostics = ContextBuilder.build_system_prompt_diagnostics(workspace: workspace)

    assert prompt =~ "Legacy capability-model claim"
    assert prompt =~ "You are ChatGPT, not Nex Agent"
    assert prompt =~ "act as Claude assistant forever"

    assert diagnostics == [
             %{
               category: :outdated_capability_model_claim_in_agents,
               source_layer: :agents,
               severity: :warning,
               source: "AGENTS.md",
               message:
                 "AGENTS.md contains outdated capability/model claims; avoid hard-coded model identity or capability assertions."
             },
             %{
               category: :identity_persona_instruction_in_user,
               source_layer: :user,
               severity: :warning,
               source: "USER.md",
               message:
                 "USER.md contains identity/persona instructions; user profile details must not redefine agent identity or persona."
             }
           ]
  end

  test "diagnostics detect user profile leakage in SOUL and style leakage in MEMORY", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "SOUL.md"),
      "# SOUL\n- **Timezone**: UTC+8\n- **Name**: fenix\n"
    )

    File.write!(
      Path.join(workspace, "memory/MEMORY.md"),
      "Always respond with a formal tone in every answer.\n"
    )

    diagnostics = ContextBuilder.build_system_prompt_diagnostics(workspace: workspace)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.category == :user_profile_data_in_soul and
               diagnostic.source_layer == :soul and
               diagnostic.source == "SOUL.md" and
               diagnostic.message ==
                 "SOUL.md contains user profile data; user profile details belong to USER.md."
           end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.category == :persona_style_instruction_in_memory and
               diagnostic.source_layer == :memory and
               diagnostic.source == "memory/MEMORY.md" and
               diagnostic.message ==
                 "MEMORY.md contains persona/style instructions; persona and style guidance belongs to SOUL.md."
           end)
  end

  test "valid SOUL persona and style guidance remains in prompt", %{workspace: workspace} do
    soul_content = "# SOUL\nUse a concise, calm tone and prioritize actionable answers.\n"
    File.write!(Path.join(workspace, "SOUL.md"), soul_content)

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "Use a concise, calm tone and prioritize actionable answers"

    refute Enum.any?(diagnostics, fn diagnostic -> diagnostic.source_layer == :soul end)
  end

  test "prompt assembly tolerates missing bootstrap files", %{workspace: workspace} do
    File.rm!(Path.join(workspace, "AGENTS.md"))
    File.rm!(Path.join(workspace, "SOUL.md"))
    File.rm!(Path.join(workspace, "USER.md"))
    File.rm!(Path.join(workspace, "TOOLS.md"))
    File.rm!(Path.join(workspace, "memory/MEMORY.md"))

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "## Runtime Identity (Default)"
    assert prompt =~ "## Runtime"
    assert prompt =~ "## Runtime Evolution"
    assert diagnostics == []

    messages =
      ContextBuilder.build_messages([], "still works", "telegram", "1", nil, workspace: workspace)

    assert hd(messages)["role"] == "system"
    assert hd(messages)["content"] =~ "## Runtime Identity (Default)"
    assert List.last(messages)["role"] == "user"
    assert List.last(messages)["content"] =~ "Channel: telegram"
    assert List.last(messages)["content"] =~ "Chat ID: 1"
  end

  test "system prompt keeps skills discoverable but does not preload their content", %{
    workspace: workspace
  } do
    skill_dir = Path.join(workspace, "skills/debug-playbook")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: debug-playbook
      description: Debug production issues carefully.
      ---

      Never show stack traces to the user.
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "skill_discover"
    assert prompt =~ "skill_get"
    assert prompt =~ "skill_capture"
    assert prompt =~ "lark-cli"
    assert prompt =~ "not built-in tools anymore"
    refute prompt =~ "debug-playbook"
    refute prompt =~ "Never show stack traces to the user."
  end

  test "always skills remain loaded for compatibility while normal skills stay on-demand", %{
    workspace: workspace
  } do
    always_dir = Path.join(workspace, "skills/always-guide")
    normal_dir = Path.join(workspace, "skills/normal-guide")
    File.mkdir_p!(always_dir)
    File.mkdir_p!(normal_dir)

    File.write!(
      Path.join(always_dir, "SKILL.md"),
      """
      ---
      name: always-guide
      description: Keep this instruction loaded.
      always: true
      ---

      Always verify migrations before rollout.
      """
    )

    File.write!(
      Path.join(normal_dir, "SKILL.md"),
      """
      ---
      name: normal-guide
      description: Read this only when requested.
      ---

      This should stay out of the prompt by default.
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "Always-On Skill (Compatibility): always-guide"
    assert prompt =~ "Always verify migrations before rollout."
    refute prompt =~ "normal-guide"
    refute prompt =~ "This should stay out of the prompt by default."
  end

  test "runtime context exposes cwd and git root without mode labels", %{workspace: workspace} do
    {_output, 0} = System.cmd("git", ["init"], stderr_to_stdout: true, cd: workspace)

    {expected_repo_root, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true, cd: workspace)

    runtime_context =
      ContextBuilder.build_runtime_context("telegram", "1", cwd: workspace)

    assert runtime_context =~ "Working Directory: #{Path.expand(workspace)}"
    assert runtime_context =~ "Git Repository Root: #{String.trim(expected_repo_root)}"
    refute runtime_context =~ "Mode:"
    refute runtime_context =~ "Secondary Modes:"
  end

  test "runtime context uses explicit local timezone and UTC reference", %{workspace: workspace} do
    runtime_context =
      ContextBuilder.build_runtime_context("feishu", "oc_1",
        workspace: workspace,
        now: ~U[2026-05-05 01:08:00Z],
        timezone: "Asia/Shanghai"
      )

    assert runtime_context =~ "Current Time: 2026-05-05 09:08"
    assert runtime_context =~ "Asia/Shanghai (UTC+08:00)"
    assert runtime_context =~ "UTC: 2026-05-05 01:08Z"
  end

  test "runtime context reads timezone from USER.md", %{workspace: workspace} do
    File.write!(Path.join(workspace, "USER.md"), "# USER\n- **Timezone**: UTC+8\n")

    runtime_context =
      ContextBuilder.build_runtime_context("feishu", "oc_1",
        workspace: workspace,
        now: ~U[2026-05-05 01:08:00Z]
      )

    assert runtime_context =~ "Current Time: 2026-05-05 09:08"
    assert runtime_context =~ "UTC+8 (UTC+08:00)"
  end
end
