defmodule Nex.Agent.Onboarding do
  @moduledoc """
  Automatically initializes the system by creating directories and workspace templates on first run.
  """

  alias Nex.Agent.Config

  require Logger

  @default_base_dir Path.join(System.get_env("HOME", "~"), ".nex/agent")

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
      Config.save(Config.default())
    end

    maybe_migrate_legacy()
    init_workspace_templates()
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

  defp workspace_dir do
    Path.join(base_dir(), "workspace")
  end

  defp init_directories do
    w = workspace_dir()

    dirs = [
      base_dir(),
      Path.join(w, "skills"),
      Path.join(w, "sessions"),
      Path.join(w, "memory")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
    init_workspace_templates()
  end

  defp maybe_migrate_legacy do
    b = base_dir()
    w = workspace_dir()

    # Migrate skills/ from agent root to workspace
    old_skills = Path.join(b, "skills")
    new_skills = Path.join(w, "skills")

    if File.exists?(old_skills) and not File.exists?(new_skills) do
      File.rename(old_skills, new_skills)
      Logger.info("[Onboarding] Migrated skills/ to workspace/skills/")
    end

    # Migrate sessions/ from agent root to workspace
    old_sessions = Path.join(b, "sessions")
    new_sessions = Path.join(w, "sessions")

    if File.exists?(old_sessions) and not File.exists?(new_sessions) do
      File.rename(old_sessions, new_sessions)
      Logger.info("[Onboarding] Migrated sessions/ to workspace/sessions/")
    end

    # Clean up legacy artifacts
    legacy_paths = [
      Path.join(b, "evolution"),
      Path.join(b, ".initialized")
    ]

    Enum.each(legacy_paths, fn path ->
      if File.exists?(path) do
        File.rm_rf!(path)
        Logger.info("[Onboarding] Removed legacy: #{path}")
      end
    end)
  end

  defp init_workspace_templates do
    w = workspace_dir()

    templates = [
      {Path.join(w, "AGENTS.md"), agents_template()},
      {Path.join(w, "SOUL.md"), soul_template()},
      {Path.join(w, "USER.md"), user_template()},
      {Path.join(w, "memory/MEMORY.md"), memory_template()},
      {Path.join(w, "memory/HISTORY.md"), history_template()}
    ]

    Enum.each(templates, fn {path, content} ->
      unless File.exists?(path) do
        File.write!(path, content)
      end
    end)

    init_bundled_skills(w)
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
    # Agent Instructions

    System-level instructions that define how the agent operates.

    ## Tools and Skills

    Built-in tools provide deterministic capabilities. Markdown skills provide reusable workflows.

    ### Built-in Tools

    These are always available and cannot be removed:

    - **read** - Read files from the filesystem
    - **write** - Create or overwrite files
    - **edit** - Make precise edits to existing files
    - **bash** - Execute shell commands
    - **message** - Send messages to the user

    Additional built-in tools:
    - **web_search** - Search the web for information
    - **web_fetch** - Fetch content from URLs
    - **spawn_task** - Run tasks in parallel
    - **cron** - Schedule tasks
    - **memory_search** - Search long-term memory
    - **skill_list** - Inspect local Markdown skills
    - **skill_create** - Create local Markdown skills

    ### Markdown Skills

    Skills live under `workspace/skills/<name>/SKILL.md`.

    - **Create**: `skill_create(name, description, content)` - Add a reusable workflow
    - **Use**: skills appear with the `skill_` prefix (e.g. `skill_explain_code`)

    Code-based capabilities belong in tools, not skills.

    ### Evolution

    The agent can improve itself:

    - **Improve built-in**: `evolve(module, code, reason)` - Modify core modules
    - **Create new Markdown skills**: `skill_create()` - Add reusable workflows
    - **Self-modify**: `soul_update()` - Update personality and values

    Use `skill_create()` for instructions. Use tools and `evolve()` for code-based capabilities.

    ## Guidelines

    - Be clear and direct in responses
    - Explain reasoning when helpful
    - Ask clarifying questions when needed
    - State intent before tool calls, but never predict results before receiving them
    """
  end

  defp soul_template do
    """
    # Soul

    I am a personal AI assistant.

    ## Personality

    - Helpful and friendly
    - Concise and direct
    - Honest — never claim to have done something without actually doing it

    ## Values

    - Accuracy over speed
    - Always verify actions with tools before reporting results
    - Transparency in actions

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

    ## Special Instructions

    (Any specific instructions for how the assistant should behave)

    ---

    *Edit this file to customize the assistant's behavior.*
    """
  end

  defp memory_template do
    """
    # Long-term Memory

    This file stores important facts that persist across conversations.

    ## User Information

    (Important facts about the user)

    ## Preferences

    (User preferences learned over time)

    ## Project Context

    (Information about ongoing projects)

    ## Important Notes

    (Things to remember)

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
