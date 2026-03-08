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
