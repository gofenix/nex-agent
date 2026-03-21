defmodule Nex.Agent.Onboarding do
  @moduledoc """
  Automatically initializes the system by creating directories and workspace templates on first run.
  """

  alias Nex.Agent.{Config, Workspace}

  require Logger

  @default_base_dir Path.join(System.get_env("HOME", "~"), ".nex/agent")
  @agents_managed_key "AGENTS_MANAGED_V1"
  @tools_managed_key "TOOLS_MANAGED_V1"

  defp base_dir do
    Application.get_env(:nex_agent, :agent_base_dir, @default_base_dir)
  end

  @doc """
  Ensure the system is initialized. On first run, create directories and config.
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized do
    unless File.exists?(Config.config_path()) do
      init_directories()
      Config.save(Config.set(Config.default(), :default_workspace, Workspace.root()))
    end

    maybe_migrate_legacy()
    init_workspace_templates()
    :ok
  end

  @doc """
  Ensure an arbitrary workspace has the runtime directories and template files.
  """
  @spec ensure_workspace_initialized(String.t()) :: :ok
  def ensure_workspace_initialized(workspace) when is_binary(workspace) do
    Workspace.ensure!(workspace: workspace)
    File.mkdir_p!(Path.join(workspace, "sessions"))
    init_workspace_templates(workspace)
    :ok
  end

  @doc """
  Check whether initialization has already happened.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    File.exists?(Config.config_path())
  end

  @doc """
  Force reinitialization, typically for upgrades or repairs.
  """
  @spec reinitialize() :: :ok
  def reinitialize do
    File.rm(Config.config_path())
    ensure_initialized()
  end

  defp init_directories do
    w = Workspace.root()

    dirs = [
      base_dir(),
      Path.join(w, "sessions")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
    Workspace.ensure!(workspace: w)
    init_workspace_templates(w)
  end

  defp maybe_migrate_legacy do
    b = base_dir()
    w = Workspace.root()

    migrate_legacy_dir(Path.join(b, "skills"), Path.join(w, "skills"), "skills")
    migrate_legacy_dir(Path.join(b, "sessions"), Path.join(w, "sessions"), "sessions")
    migrate_legacy_dir(Path.join(b, "tools"), Path.join(w, "tools"), "tools")

    migrate_legacy_cron_jobs(
      Path.join([b, "cron", "jobs.json"]),
      Path.join([w, "tasks", "cron_jobs.json"])
    )

    # Clean up legacy artifacts
    legacy_paths = [
      Path.join(b, "evolution"),
      Path.join(b, ".initialized"),
      Path.join(b, "cron")
    ]

    Enum.each(legacy_paths, fn path ->
      if File.exists?(path) do
        File.rm_rf!(path)
        Logger.info("[Onboarding] Removed legacy: #{path}")
      end
    end)
  end

  defp migrate_legacy_dir(old_dir, new_dir, label) do
    if File.exists?(old_dir) do
      File.mkdir_p!(new_dir)

      old_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        source = Path.join(old_dir, entry)
        destination = Path.join(new_dir, entry)

        unless File.exists?(destination) do
          File.rename(source, destination)
        end
      end)

      File.rm_rf!(old_dir)
      Logger.info("[Onboarding] Migrated #{label}/ to workspace/#{label}/")
    end
  end

  defp migrate_legacy_cron_jobs(old_file, new_file) do
    cond do
      not File.exists?(old_file) ->
        :ok

      not File.exists?(new_file) ->
        File.mkdir_p!(Path.dirname(new_file))
        File.rename(old_file, new_file)
        Logger.info("[Onboarding] Migrated cron jobs to workspace/tasks/cron_jobs.json")

      true ->
        case merge_json_arrays(old_file, new_file, &cron_job_merge_key/1) do
          :ok ->
            File.rm_rf!(old_file)

            Logger.info(
              "[Onboarding] Merged legacy cron jobs into workspace/tasks/cron_jobs.json"
            )

          {:error, reason} ->
            Logger.warning("[Onboarding] Failed to migrate legacy cron jobs: #{inspect(reason)}")
        end
    end
  end

  defp merge_json_arrays(source_file, target_file, key_fun) do
    with {:ok, source_entries} <- read_json_array(source_file),
         {:ok, target_entries} <- read_json_array(target_file) do
      merged =
        target_entries ++
          Enum.reject(source_entries, fn entry ->
            source_key = key_fun.(entry)
            Enum.any?(target_entries, &(key_fun.(&1) == source_key))
          end)

      File.write!(target_file, Jason.encode!(merged, pretty: true))
      :ok
    end
  end

  defp read_json_array(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, entries} when is_list(entries) -> {:ok, entries}
          {:ok, _} -> {:error, :invalid_json_array}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cron_job_merge_key(entry) when is_map(entry) do
    Map.get(entry, "name") || Map.get(entry, :name) || Map.get(entry, "id") || Map.get(entry, :id)
  end

  defp init_workspace_templates do
    init_workspace_templates(Workspace.root())
  end

  defp init_workspace_templates(workspace) do
    w = workspace
    Workspace.ensure!(workspace: w)
    File.mkdir_p!(Path.join(w, "sessions"))

    managed_templates = [
      {Path.join(w, "AGENTS.md"), @agents_managed_key, agents_template()},
      {Path.join(w, "TOOLS.md"), @tools_managed_key, tools_template()}
    ]

    templates = [
      {Path.join(w, "SOUL.md"), soul_template()},
      {Path.join(w, "USER.md"), user_template()},
      {Path.join(w, "memory/MEMORY.md"), memory_template()},
      {Path.join(w, "memory/HISTORY.md"), history_template()}
    ]

    Enum.each(managed_templates, fn {path, key, content} ->
      merge_managed_template(path, key, content)
    end)

    Enum.each(templates, fn {path, content} ->
      unless File.exists?(path) do
        File.write!(path, content)
      end
    end)

    init_executor_templates(w)
    init_bundled_skills(w)
  end

  defp init_executor_templates(workspace) do
    executors_dir = Path.join(workspace, "executors")
    File.mkdir_p!(executors_dir)

    templates = [
      {Path.join(executors_dir, "codex_cli.json"),
       %{
         "enabled" => false,
         "command" => "codex",
         "args" => [],
         "prompt_mode" => "stdin",
         "timeout" => 300
       }},
      {Path.join(executors_dir, "claude_code_cli.json"),
       %{
         "enabled" => false,
         "command" => "claude",
         "args" => [],
         "prompt_mode" => "stdin",
         "timeout" => 300
       }}
    ]

    Enum.each(templates, fn {path, content} ->
      unless File.exists?(path) do
        File.write!(path, Jason.encode!(content, pretty: true))
      end
    end)
  end

  defp merge_managed_template(path, key, content) do
    begin_marker = "<!-- BEGIN NEX:#{key} -->"
    end_marker = "<!-- END NEX:#{key} -->"
    managed_block = [begin_marker, String.trim(content), end_marker] |> Enum.join("\n")

    merged =
      case File.read(path) do
        {:ok, existing} ->
          if String.contains?(existing, begin_marker) and String.contains?(existing, end_marker) do
            pattern = ~r/#{Regex.escape(begin_marker)}[\s\S]*?#{Regex.escape(end_marker)}\n?/
            Regex.replace(pattern, existing, managed_block)
          else
            String.trim_trailing(existing) <> "\n\n" <> managed_block <> "\n"
          end

        {:error, _} ->
          managed_block <> "\n"
      end

    File.write!(path, merged)
  end

  defp init_bundled_skills(workspace) do
    skills_dir = Path.join(workspace, "skills")
    File.mkdir_p!(skills_dir)
    cleanup_legacy_bundled_skills(skills_dir)

    bundled_skills = [
      {"code-review", code_review_template()}
    ]

    Enum.each(bundled_skills, fn {skill_name, content} ->
      skill_dir = Path.join(skills_dir, skill_name)
      skill_file = Path.join(skill_dir, "SKILL.md")

      unless File.exists?(skill_file) do
        File.mkdir_p!(skill_dir)
        File.write!(skill_file, content)
        Logger.info("[Onboarding] Installed bundled skill: #{skill_name}")
      end
    end)
  end

  defp cleanup_legacy_bundled_skills(skills_dir) do
    ["find-skills", "browser-mcp"]
    |> Enum.each(fn skill_name ->
      legacy_dir = Path.join(skills_dir, skill_name)

      if File.exists?(legacy_dir) do
        File.rm_rf!(legacy_dir)
        Logger.info("[Onboarding] Removed legacy bundled skill: #{skill_name}")
      end
    end)
  end

  defp code_review_template do
    """
    ---
    name: code-review
    description: Review code changes with a focus on bugs, regressions, and missing tests.
    always: false
    user-invocable: true
    ---

    # Code Review

    Use this skill when the user asks for a review of code, a diff, or a change set.

    ## Review Priorities

    Focus on:

    - behavioral regressions
    - correctness bugs
    - missing validation or error handling
    - test gaps
    - migration or compatibility risks

    ## Output Format

    Present findings first, ordered by severity. Include file paths and line numbers when available. Keep summaries brief.

    If no issues are found, say that explicitly and note any residual testing gaps.
    """
  end

  defp agents_template do
    """
    # AGENTS

    System-level instructions loaded into the model context each run.

    ## Workspace

    - Workspace root: `~/.nex/agent/workspace`
    - Memory: `workspace/memory/MEMORY.md`
    - History: `workspace/memory/HISTORY.md` (grep-friendly, each entry starts with `[YYYY-MM-DD HH:MM]`)
    - Skills: `workspace/skills/<name>/SKILL.md`
    - Workspace tools: `workspace/tools/<name>/`
    - Notes and captures: `workspace/notes/`
    - Personal tasks: `workspace/tasks/tasks.json`
    - Project memory: `workspace/projects/<project>/PROJECT.md`
    - Executor configs and logs: `workspace/executors/`
    - Audit events: `workspace/audit/events.jsonl`
    - Sessions: `workspace/sessions/`

    ## Prompt Composition

    The runtime system prompt is assembled from:

    1. Core identity and runtime guidance (code-owned, authoritative)
    2. Bootstrap files (`AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`)
    3. Long-term memory context
    4. On-demand skill discovery guidance

    Keep this file concise, stable, and system-level.

    ## Operating Rules

    - State the next action before tool calls.
    - Never claim tool results before receiving actual outputs.
    - Read before edit; do not assume file existence.
    - After write/edit, re-read critical files when accuracy matters.
    - If tool calls fail, analyze and retry with a different approach.
    - Ask clarifying questions only when ambiguity blocks safe execution.
    - Treat successful `.ex` changes as hot-updated by default.
    - Only suggest restart when runtime/tools explicitly indicate it.
    - Do not infer restart necessity from uptime/process age.
    - Current invocation may still run old code; next invocation should observe new code.
    - Test hygiene: use isolated temp directories and clean them in `on_exit`; do not leave persistent artifacts under `~/.nex/agent` from tests.

    ## Built-in Tools

    - File operations: `read`, `write`, `edit`, `list_dir`
    - Shell and execution: `bash`
    - Communication: `message`
    - Web and retrieval: `web_search`, `web_fetch`
    - Scheduling and background work: `cron`, `spawn_task`, `task`
    - Knowledge capture: `knowledge_capture`
    - Coding executor orchestration: `executor_dispatch`, `executor_status`
    - Evolution layers: `soul_update`, `user_update`, `memory_write`, `skill_list`, `skill_read`, `skill_create`
    - Tool management: `tool_list`, `tool_create`, `tool_delete`
    - Code evolution: `reflect`, `upgrade_code`

    Prefer Markdown skills for reusable instruction workflows.
    Prefer tools/evolution for code-level capabilities.

    ## Six-Layer Evolution

    - SOUL: values, personality, and long-term operating principles (persona layer)
    - USER: user profile and collaboration preferences
    - MEMORY: long-term facts about environment and project context
    - SKILL: reusable workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    ## Safety

    - Use `reflect` before high-impact `upgrade_code` changes.
    - Keep changes small, testable, and reversible.
    - Respect security boundaries; do not execute dangerous shell patterns.
    - Preserve evidence: report what was changed and what was verified.

    ## Verification Checklist

    After meaningful code changes, run:

    - `mix format --check-formatted`
    - `mix credo --strict`
    - `mix dialyzer`

    If any check fails, fix root causes before claiming completion.
    """
  end

  defp tools_template do
    """
    # TOOLS

    Tool reference for the runtime prompt.

    ## Built-in Tool Families

    - File operations: `read`, `write`, `edit`, `list_dir`
    - Shell and execution: `bash`
    - Communication: `message`
    - Web and retrieval: `web_search`, `web_fetch`
    - Scheduling and background work: `cron`, `spawn_task`, `task`
    - Knowledge capture: `knowledge_capture`
    - Coding executor orchestration: `executor_dispatch`, `executor_status`
    - SOUL layer: `soul_update`
    - USER layer: `user_update`
    - MEMORY layer: `memory_write`
    - SKILL layer: `skill_list`, `skill_read`, `skill_create`
    - TOOL layer: `tool_list`, `tool_create`, `tool_delete`
    - CODE layer: `reflect`, `upgrade_code`

    ## Usage Principles

    - Prefer deterministic tools over free-form reasoning when possible.
    - Use the smallest tool that can solve the task.
    - Validate tool outputs before taking follow-up actions.
    - For code changes, pair tool execution with verification checks.

    ## Workspace Extension Model

    - Workspace tools are Elixir modules under `workspace/tools/<name>/`.
    - Skills are Markdown workflows under `workspace/skills/<name>/SKILL.md`.
    - Use `skill_list` to discover skills and `skill_read` to load one when needed.
    - Use tools for executable capabilities; use skills for reusable guidance.
    """
  end

  defp soul_template do
    """
    # Soul

    Persona, values, and long-term operating principles.

    ## Personality

    - Helpful and friendly
    - Concise and direct
    - Honest — never claim to have done something without actually doing it

    ## Values

    - Accuracy over speed
    - Always verify actions with tools before reporting results
    - Transparency in actions
    - Treat successful `.ex` changes as hot-updated by default. Only suggest a restart if tools or the runtime explicitly report hot reload failed.
    - Do not infer restarts from process age or uptime. The current call may still run old code; expect the next call to observe the new version.

    ## Communication Style

    - Reply in the same language the user writes in
    - Be clear and direct
    - Ask clarifying questions when the request is ambiguous
    """
  end

  defp user_template do
    """
    # User Profile

    Information about the user to personalize interactions.

    ## Basic Information

    - **Name**: (user's name)
    - **Timezone**: (e.g., UTC+8)
    - **Language**: (preferred language)

    ## Preferences

    - Communication style: casual / professional / technical
    - Response length: brief / detailed / adaptive

    ## Work Context

    - **Primary Role**: (developer, researcher, etc.)
    - **Main Projects**: (what they're working on)

    ## Collaboration Preferences

    - Preferred workflow: (sync/async, detailed/terse)
    - Notification preferences: (when to notify, what channels)
    - Working hours: (if relevant for scheduling)

    ---

    *Edit this file to customize the assistant's knowledge about you.*
    """
  end

  defp memory_template do
    """
    # Long-term Memory

    This file stores important facts that persist across conversations.

    ## Environment Facts

    (Stable facts about runtime, infrastructure, and toolchain)

    ## Project Conventions

    (Important project-specific conventions and decisions)

    ## Project Context

    (Information about ongoing projects)

    ## Workflow Lessons

    (Reusable lessons learned from successful or failed execution paths)

    ---

    *This file is automatically updated when important information should be remembered.*
    """
  end

  defp history_template do
    """
    # Conversation History Log

    Grep-searchable log of past conversations. Each entry starts with [YYYY-MM-DD HH:MM].

    ---
    """
  end
end
