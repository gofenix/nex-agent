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

    bundled_skills = [
      {"find-skills", find_skills_template()},
      {"browser-mcp", browser_mcp_template()}
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

  defp find_skills_template do
    """
    ---
    name: find-skills
    description: Helps users discover and install agent skills when they ask questions like "how do I do X", "find a skill for X", "is there a skill that can...", or express interest in extending capabilities.
    always: false
    user-invocable: true
    ---

    # Find Skills

    This skill helps you discover and install skills from the open agent skills ecosystem (skills.sh).

    ## When to Use This Skill

    Use this skill when the user:

    - Asks "how do I do X" where X might be a common task with an existing skill
    - Says "find a skill for X" or "is there a skill for X"
    - Asks "can you do X" where X is a specialized capability
    - Expresses interest in extending agent capabilities
    - Wants to search for tools, templates, or workflows
    - Mentions they wish they had help with a specific domain (design, testing, deployment, etc.)

    ## How to Help Users Find Skills

    ### Step 1: Understand What They Need

    When a user asks for help, identify:
    1. The domain (e.g., React, testing, design, deployment)
    2. The specific task (e.g., writing tests, creating animations, reviewing PRs)
    3. Whether this is a common enough task that a skill likely exists

    ### Step 2: Search for Skills

    Use the built-in `skill_search` tool to search skills.sh:

    ```
    skill_search(query: "react performance")
    ```

    You can also suggest using the Skills CLI:

    ```bash
    npx skills find [query]
    ```

    ### Step 3: Present Options

    When you find relevant skills, present them with:
    1. The skill name and description
    2. What it does and why it's useful
    3. The install command: `skill_install("owner/repo/skill-name")`
    4. A link to learn more: https://skills.sh/owner/repo/skill-name

    Example:

    ```
    I found 3 relevant skills:

    1. vercel-react-best-practices (184K installs)
       - React and Next.js performance optimization guidelines
       - Install: skill_install("vercel-labs/agent-skills/vercel-react-best-practices")

    2. react-testing (45K installs)
       - Best practices for testing React components
       - Install: skill_install("anthropics/skills/react-testing")

    Which would you like to install?
    ```

    ### Step 4: Install

    If the user wants to proceed, use `skill_install`:

    ```
    skill_install("owner/repo/skill-name")
    ```

    After installation, verify it works by explaining what new capabilities are now available.

    ## Common Skill Categories

    When searching, consider these common categories:

    | Category        | Example Queries                          |
    | --------------- | ---------------------------------------- |
    | Web Development | react, nextjs, typescript, css, tailwind |
    | Testing         | testing, jest, playwright, e2e           |
    | DevOps          | deploy, docker, kubernetes, ci-cd        |
    | Documentation   | docs, readme, changelog, api-docs        |
    | Code Quality    | review, lint, refactor, best-practices   |
    | Design          | ui, ux, design-system, accessibility     |
    | Productivity    | workflow, automation, git                |

    ## Tips for Effective Searches

    1. **Use specific keywords**: "react testing" is better than just "testing"
    2. **Try alternative terms**: If "deploy" doesn't work, try "deployment" or "ci-cd"
    3. **Check popular sources**: 
       - `vercel-labs/agent-skills` - Vercel's official skills
       - `anthropics/skills` - Anthropic's official skills
       - `microsoft/github-copilot-for-azure` - Azure skills

    ## When No Skills Are Found

    If no relevant skills exist:

    1. Acknowledge that no existing skill was found
    2. Offer to help with the task directly using your general capabilities
    3. Suggest the user could create their own skill with `skill_create`

    Example:

    ```
    I searched for skills related to "xyz" but didn't find any matches.
    I can still help you with this task directly! Would you like me to proceed?

    If this is something you do often, you could create your own skill:
    skill_create(name: "my-xyz-skill", type: "markdown", ...)
    ```

    ## Examples

    **Example 1: User asks "How do I make my React app faster?"**

    1. Identify: Domain = React, Task = performance optimization
    2. Search: `skill_search(query: "react performance optimization")`
    3. Present: Show vercel-react-best-practices and other options
    4. Install: If user agrees, run `skill_install(...)`

    **Example 2: User asks "Is there a skill for creating changelogs?"**

    1. Identify: Domain = documentation, Task = changelog
    2. Search: `skill_search(query: "changelog")`
    3. Present: Show changelog-related skills
    4. Install: If user agrees, run `skill_install(...)`
    """
  end

  defp browser_mcp_template do
    """
    ---
    name: browser-mcp
    description: Browser automation via MCP (Model Context Protocol). Control browser to navigate, click, type, screenshot, and more. Manages MCP connection automatically.
    type: elixir
    user-invocable: true
    parameters:
      action:
        type: string
        enum: ["navigate", "click", "type", "screenshot", "snapshot", "go_back", "go_forward", "wait"]
        description: Browser action to perform
      url:
        type: string
        description: URL for navigate action
      selector:
        type: string
        description: CSS selector for click/type actions
      text:
        type: string
        description: Text to type
      element:
        type: string
        description: Element reference from snapshot
      milliseconds:
        type: integer
        description: Wait time in milliseconds
    allowed_tools:
      - message
    ---

    # Browser MCP

    This skill provides browser automation capabilities via the MCP (Model Context Protocol).

    ## Prerequisites

    - Node.js installed
    - npx available in PATH

    ## Usage

    When you use this skill, it will automatically start the MCP browser server and execute browser actions.

    ### Available Actions

    | Action | Description | Parameters |
    |--------|-------------|------------|
    | navigate | Navigate to a URL | url (required) |
    | click | Click an element | selector or element (required) |
    | type | Type text into an input | selector or element (required), text (required) |
    | screenshot | Take a screenshot | - |
    | snapshot | Get page DOM snapshot | - |
    | go_back | Go back in history | - |
    | go_forward | Go forward in history | - |
    | wait | Wait for specified time | milliseconds (optional, default 1000) |

    ### Examples

    ```elixir
    # Navigate to a website
    %{"action" => "navigate", "url" => "https://twitter.com"}

    # Click an element
    %{"action" => "click", "selector" => ".submit-button"}

    # Type text
    %{"action" => "type", "selector" => "input[name='search']", "text" => "hello"}

    # Take screenshot
    %{"action" => "screenshot"}

    # Get page snapshot
    %{"action" => "snapshot"}
    ```

    ## Notes

    - The MCP server is started automatically on first use
    - The browser connection persists across multiple actions
    - Use `snapshot` to get clickable element references
    - Screenshots are returned as base64 images
    """
  end

  defp agents_template do
    """
    # Agent Instructions

    System-level instructions that define how the agent operates.

    ## Skills System

    All capabilities are Skills. Skills are divided into two categories:

    ### Built-in Skills (Core)

    These are always available and cannot be removed:

    - **read** - Read files from the filesystem
    - **write** - Create or overwrite files
    - **edit** - Make precise edits to existing files
    - **bash** - Execute shell commands
    - **message** - Send messages to the user

    Additional built-in skills:
    - **web_search** - Search the web for information
    - **web_fetch** - Fetch content from URLs
    - **spawn_task** - Run tasks in parallel
    - **cron** - Schedule tasks
    - **memory_search** - Search long-term memory

    ### Extended Skills (User-installed)

    Skills can be installed from the community or created by the agent:

    - **Install**: `skill_install("owner/repo/skill-name")` - Install from skills.sh
    - **Create**: `skill_create(name, type, content)` - Create new skills
      - `markdown` - Instructions and prompts (injected into context)
      - `script` - Bash scripts for automation
      - `elixir` - Full Elixir modules (auto-registered as callable skills)
      - `mcp` - External service integrations

    Extended skills appear with `skill_` prefix (e.g., `skill_explain_code`).

    ### Evolution

    The agent can improve itself:

    - **Improve built-in**: `evolve(module, code, reason)` - Modify core modules
    - **Create new skills**: `skill_create()` - Add new capabilities
    - **Self-modify**: `soul_update()` - Update personality and values

    When creating new capabilities, prefer `skill_create()` over modifying source code.

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
