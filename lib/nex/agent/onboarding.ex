defmodule Nex.Agent.Onboarding do
  @moduledoc """
  Automatically initializes the system by creating directories and default skills on first run.
  """

  @default_base_dir Path.join(System.get_env("HOME", "~"), ".nex/agent")

  @default_skills [
    {"explain-code", :markdown},
    {"git-commit", :script},
    {"project-analyze", :markdown},
    {"test-runner", :markdown},
    {"refactor-suggest", :markdown},
    {"todo", :elixir}
  ]

  defp base_dir do
    Application.get_env(:nex_agent, :agent_base_dir, @default_base_dir)
  end

  defp initialized_file do
    Path.join(base_dir(), ".initialized")
  end

  defp skills_dir do
    Path.join(base_dir(), "skills")
  end

  @doc """
  Ensure the system is initialized. On first run, create directories and default skills automatically.
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized do
    unless initialized?() do
      init_directories()
      init_default_skills()
      mark_initialized()
    end

    init_workspace_templates()
    :ok
  end

  @doc """
  Check whether initialization has already happened.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    File.exists?(initialized_file())
  end

  @doc """
  Force reinitialization, typically for upgrades or repairs.
  """
  @spec reinitialize() :: :ok
  def reinitialize do
    File.rm(initialized_file())
    ensure_initialized()
  end

  @doc """
  Return the list of default skills.
  """
  @spec default_skills() :: list({String.t(), atom()})
  def default_skills, do: @default_skills

  defp workspace_dir do
    Path.join(base_dir(), "workspace")
  end

  defp init_directories do
    b = base_dir()

    dirs = [
      b,
      skills_dir(),
      Path.join(b, "sessions"),
      Path.join(b, "evolution"),
      Path.join(workspace_dir(), "memory")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
    init_workspace_templates()
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

  defp init_default_skills do
    Enum.each(@default_skills, fn {name, type} ->
      skill_dir = Path.join(skills_dir(), name)

      unless File.exists?(skill_dir) do
        create_skill(name, type, skill_dir)
      end
    end)
  end

  defp create_skill(name, :markdown, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :markdown)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: markdown
    user-invocable: true
    ---

    #{content.body}
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
  end

  defp create_skill(name, :script, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :script)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: script
    user-invocable: true
    ---

    See script.sh for implementation.
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    File.write!(Path.join(skill_dir, "script.sh"), content.script)

    script_path = Path.join(skill_dir, "script.sh")
    File.chmod(script_path, 0o755)
  end

  defp create_skill(name, :elixir, skill_dir) do
    File.mkdir_p!(skill_dir)

    content = get_skill_content(name, :elixir)

    skill_md = """
    ---
    name: #{name}
    description: #{content.description}
    type: elixir
    user-invocable: true
    ---

    See skill.ex for implementation.
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    File.write!(Path.join(skill_dir, "skill.ex"), content.code)
  end

  defp mark_initialized do
    skill_names = Enum.map_join(@default_skills, ",", fn {n, _} -> n end)

    content = """
    version: 1
    created: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    skills: #{skill_names}
    """

    File.write!(initialized_file(), content)
  end

  defp get_skill_content("explain-code", :markdown) do
    %{
      description: "Explain code logic with a flow diagram",
      body: """
      When analyzing code:

      1. Summarize the core function in one sentence
      2. Draw a data-flow diagram using ASCII art
      3. List the key functions and their responsibilities
      4. Point out potential improvements

      Example output format:

      ```
      ## Overview
      [One-sentence summary]

      ## Data Flow
      [ASCII diagram]

      ## Key Functions
      - func1: responsibility
      - func2: responsibility

      ## Improvement Suggestions
      - [suggestion 1]
      - [suggestion 2]
      ```
      """
    }
  end

  defp get_skill_content("git-commit", :script) do
    %{
      description: "Generate a commit message from staged changes",
      script: """
      #!/bin/bash
      # Generate commit message from staged changes

      # Get staged diff
      DIFF=$(git diff --cached --stat)

      if [ -z "$DIFF" ]; then
        echo "No staged changes. Use 'git add' first."
        exit 1
      fi

      # Get file list
      FILES=$(git diff --cached --name-only)

      # Analyze changes
      echo "Staged files:"
      echo "$FILES"
      echo ""
      echo "Changes summary:"
      echo "$DIFF"
      """
    }
  end

  defp get_skill_content("project-analyze", :markdown) do
    %{
      description: "Analyze project structure and architecture",
      body: """
      When analyzing a project:

      1. List the directory structure (`tree -L 2`)
      2. Identify the tech stack (language, framework, database)
      3. Find the entry files
      4. Draw the module dependency graph

      Output format:

      ```
      ## Tech Stack
      - Language: ...
      - Framework: ...
      - Database: ...

      ## Directory Structure
      [tree output]

      ## Entry Points
      - ...

      ## Module Relationships
      [dependency graph]
      ```
      """
    }
  end

  defp get_skill_content("test-runner", :markdown) do
    %{
      description: "Run tests and analyze failures",
      body: """
      Run tests:

      1. Execute `mix test`
      2. Collect failing tests
      3. Analyze why they failed
      4. Provide fix suggestions

      Command:
      ```bash
      mix test --trace
      ```

      When analyzing failed tests:
      - Check the exact assertion failure location
      - Compare expected and actual values
      - Verify that test data is correct
      - Verify that dependencies are mocked correctly
      """
    }
  end

  defp get_skill_content("refactor-suggest", :markdown) do
    %{
      description: "Provide refactoring suggestions",
      body: """
      Refactoring analysis:

      1. Identify code smells
         - Overly long functions
         - Repeated code
         - Excessive nesting
         - Too many parameters

      2. Suggest refactoring patterns
         - Extract functions
         - Extract modules
         - Simplify conditions
         - Eliminate duplication

      3. Evaluate risks and benefits
         - Scope of change
         - Test coverage
         - Potential side effects

      Output format:
      ```
      ## Issues Found
      1. [Issue description] - Location: [file:line]

      ## Refactoring Suggestions
      - [suggestion 1]
      - [suggestion 2]

      ## Risk Assessment
      - Risk: low / medium / high
      - Recommendation: [whether to refactor now]
      ```
      """
    }
  end

  defp get_skill_content("todo", :elixir) do
    %{
      description: "Task management - add, list, and complete tasks",
      code: ~S'''
      defmodule Nex.Agent.Skills.Todo do
        @moduledoc """
        Task management skill.

        Usage:
          - add: Create a new task
          - list: Show all tasks
          - done: Mark task as completed
          - clear: Remove completed tasks
        """

        def execute(%{"action" => "add", "task" => task}, _opts) do
          Nex.Agent.Memory.append("TODO: #{task}", "PENDING", %{type: :todo})
          {:ok, %{result: "Added task: #{task}"}}
        end

        def execute(%{"action" => "list"}, _opts) do
          results = Nex.Agent.Memory.search("TODO:", limit: 50)

          tasks =
            results
            |> Enum.filter(fn r -> r.entry.result in ["PENDING", "DONE"] end)
            |> Enum.map(fn r ->
              status = if r.entry.result == "DONE", do: "[x]", else: "[ ]"
              "#{status} #{r.entry.task}"
            end)

          {:ok, %{result: Enum.join(tasks, "\n")}}
        end

        def execute(%{"action" => "done", "task" => task}, _opts) do
          results = Nex.Agent.Memory.search("TODO: #{task}", limit: 1)

          case results do
            [r | _] ->
              Nex.Agent.Memory.append(r.entry.task, "DONE", %{type: :todo})
              {:ok, %{result: "Completed: #{task}"}}

            [] ->
              {:ok, %{result: "Task not found: #{task}"}}
          end
        end

        def execute(%{"action" => "clear"}, _opts) do
          {:ok, %{result: "Clear not implemented - use memory to manage"}}
        end

        def execute(_args, _opts) do
          {:ok, %{
            result: "Todo skill. Actions: add, list, done, clear. Example: {\"action\": \"add\", \"task\": \"Fix bug\"}"
          }}
        end
      end
      '''
    }
  end

  defp get_skill_content(_name, _type) do
    %{
      description: "A skill",
      body: "Skill content",
      code: "",
      script: ""
    }
  end
end
