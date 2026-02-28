defmodule Nex.Agent.Skills do
  @moduledoc """
  Unified Skills system - supports elixir, script, mcp, and markdown skills.

  ## Usage

      # Load all skills
      :ok = Nex.Agent.Skills.load()
      
      # List available skills
      skills = Nex.Agent.Skills.list()
      
      # Execute a skill
      {:ok, result} = Nex.Agent.Skills.execute("explain-code", "some arguments")

      # Create a new skill
      {:ok, skill} = Nex.Agent.Skills.create(%{
        name: "todo_add",
        description: "Add a todo item",
        type: "elixir",
        code: "# Elixir code here",
        parameters: %{"task" => %{"type" => "string"}}
      })
  """

  use Agent
  alias Nex.Agent.{Memory, Evolution}

  @name __MODULE__

  @skills_dir Path.join(System.get_env("HOME", "~"), ".nex/agent/skills")

  # Client API

  @doc """
  Start the Skills agent.
  """
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts ++ [name: @name])
  end

  @doc """
  Load skills from directories.
  """
  @spec load() :: :ok
  def load do
    skills = Nex.Agent.Skills.Loader.load_all()

    Agent.update(@name, fn _state ->
      Enum.into(skills, %{}, fn skill -> {skill.name, skill} end)
    end)

    :ok
  end

  @doc """
  Reload skills from disk.
  """
  @spec reload() :: :ok
  def reload, do: load()

  @doc """
  List all loaded skills.
  """
  @spec list() :: list(map())
  def list do
    unless Process.whereis(@name), do: start_link()
    Agent.get(@name, &Map.values/1)
  end

  @doc """
  Get a skill by name.
  """
  @spec get(String.t()) :: map() | nil
  def get(name) do
    Agent.get(@name, &Map.get(&1, name))
  end

  @doc """
  Create a new skill.

  ## Parameters

  * `name` - Skill name (snake_case)
  * `description` - Skill description
  * `type` - Skill type: "elixir", "script", "mcp", or "markdown"
  * `code` - The actual code/script/content
  * `parameters` - JSON Schema for parameters
  * `allowed_tools` - List of allowed tools (optional)

  ## Examples

      Nex.Agent.Skills.create(%{
        name: "todo_add",
        description: "Add a todo item",
        type: "elixir",
        code: "defmodule ... end",
        parameters: %{"task" => %{"type" => "string"}}
      })
  """
  @spec create(map()) :: {:ok, map()} | {:error, String.t()}
  def create(attrs) do
    name = attrs["name"] || attrs[:name]
    type = attrs["type"] || attrs[:type] || "markdown"
    description = attrs["description"] || attrs[:description] || ""
    code = attrs["code"] || attrs[:content] || ""
    parameters = attrs["parameters"] || %{}
    allowed_tools = attrs["allowed_tools"] || attrs[:allowed_tools] || []

    if is_nil(name) do
      {:error, "Skill name is required"}
    else
      # Create skill directory
      skill_dir = Path.join(@skills_dir, name)
      File.mkdir_p!(skill_dir)

      # Save skill based on type
      case type do
        "elixir" ->
          save_elixir_skill(skill_dir, name, description, code, parameters, allowed_tools)

        "script" ->
          save_script_skill(skill_dir, name, description, code, parameters, allowed_tools)

        "mcp" ->
          save_mcp_skill(skill_dir, name, description, code, parameters, allowed_tools)

        "markdown" ->
          save_markdown_skill(skill_dir, name, description, code, parameters, allowed_tools)

        _ ->
          {:error, "Unknown skill type: #{type}"}
      end
    end
  end

  @doc """
  Delete a skill by name.
  """
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(name) do
    skill_dir = Path.join(@skills_dir, name)

    if File.exists?(skill_dir) do
      File.rm_rf!(skill_dir)
      # Remove from registry
      if Process.whereis(@name) do
        Agent.update(@name, &Map.delete(&1, name))
      end

      :ok
    else
      {:error, "Skill not found: #{name}"}
    end
  end

  @doc """
  Execute a skill.

  ## Options

  * `:context` - `:inline` (default) or `:fork`
  * `:tools` - List of allowed tools (overrides skill's allowed_tools)

  ## Examples

      Nex.Agent.Skills.execute("explain-code", "how does this work?")
      Nex.Agent.Skills.execute("deploy", "production", context: :fork)
  """
  @spec execute(String.t(), map() | String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(name, arguments, opts \\ []) do
    # Normalize arguments to map
    args =
      if is_binary(arguments) do
        %{"arguments" => arguments}
      else
        arguments
      end

    skill = get(name)

    if skill do
      if skill.disable_model_invocation && Keyword.get(opts, :invoked_by, :user) == :model do
        {:error, "Skill #{name} is disabled for model invocation"}
      else
        execute_skill(skill, args, opts)
      end
    else
      {:error, "Skill not found: #{name}"}
    end
  end

  @doc """
  Format skills for LLM function calling.
  """
  @spec for_llm() :: list(map())
  def for_llm do
    unless Process.whereis(@name), do: start_link()

    list()
    |> Enum.filter(& &1.user_invocable)
    |> Enum.map(fn skill ->
      schema = skill.parameters || %{}

      %{
        "name" => "skill_#{skill.name}",
        "description" => skill.description,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "arguments" => %{
              "type" => "object",
              "properties" => Map.new(schema, fn {k, v} -> {k, v} end)
            }
          },
          "required" => if(schema == %{}, do: ["arguments"], else: [])
        }
      }
    end)
  end

  # Private functions

  defp execute_skill(skill, arguments, opts) do
    case skill.type || "markdown" do
      "elixir" ->
        execute_elixir_skill(skill, arguments, opts)

      "script" ->
        execute_script_skill(skill, arguments, opts)

      "mcp" ->
        execute_mcp_skill(skill, arguments, opts)

      "markdown" ->
        execute_markdown_skill(skill, arguments, opts)

      _ ->
        {:error, "Unknown skill type: #{skill.type}"}
    end
  end

  defp execute_elixir_skill(skill, arguments, _opts) do
    # Dynamically compile and load the skill module
    module_name =
      Module.concat(Nex.Agent.Skills, String.replace(skill.name, "-", "_") |> String.capitalize())

    try do
      # Try to compile the code
      code = skill.code

      # Use Evolution to load the code
      case Evolution.upgrade_module(module_name, code, validate: true, backup: false) do
        {:ok, _version} ->
          # Call the execute function
          apply(module_name, :execute, [arguments, %{}])

        {:error, reason} ->
          {:error, "Failed to compile skill: #{reason}"}
      end
    rescue
      e ->
        {:error, "Skill execution failed: #{Exception.message(e)}"}
    end
  end

  defp execute_script_skill(skill, arguments, _opts) do
    # Write script to temp file and execute
    script_path = Path.join([@skills_dir, skill.name, "script.sh"])

    if File.exists?(script_path) do
      # Convert arguments map to command line args
      args_str = Jason.encode!(arguments)

      case System.cmd("bash", [script_path, args_str], stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, %{result: output}}

        {output, code} ->
          {:error, %{result: output, exit_code: code}}
      end
    else
      {:error, "Script not found: #{script_path}"}
    end
  end

  defp execute_mcp_skill(skill, arguments, _opts) do
    # For MCP skills, the code field contains MCP config JSON
    case Jason.decode(skill.code) do
      {:ok, mcp_config} ->
        # Start MCP server and call tool
        {:ok, _conn} = Nex.Agent.MCP.start_link(mcp_config)
        # TODO: Implement MCP tool calling
        {:ok, %{result: "MCP skill executed (not fully implemented)"}}

      {:error, reason} ->
        {:error, "Invalid MCP config: #{reason}"}
    end
  end

  defp execute_markdown_skill(skill, arguments, opts) do
    context = Keyword.get(opts, :context, :inline)

    case context do
      :fork ->
        content = substitute_arguments(skill.content, arguments)

        {:ok,
         %{
           content: content,
           agent: skill.agent || "general-purpose",
           tools: skill.allowed_tools || []
         }}

      :inline ->
        content = substitute_arguments(skill.content, arguments)
        {:ok, %{result: content}}
    end
  end

  defp substitute_arguments(content, arguments) when is_map(arguments) do
    args_str = Jason.encode!(arguments)

    content
    |> String.replace("$ARGUMENTS", args_str)
    |> String.replace("$0", args_str)
  end

  defp substitute_arguments(content, arguments) when is_binary(arguments) do
    content
    |> String.replace("$ARGUMENTS", arguments)
    |> String.replace("$0", arguments)
  end

  # Save functions

  defp save_elixir_skill(skill_dir, name, description, code, parameters, allowed_tools) do
    # Save the Elixir code
    code_file = Path.join(skill_dir, "skill.ex")
    File.write!(code_file, code)

    # Save metadata
    save_skill_metadata(skill_dir, name, description, "elixir", parameters, allowed_tools)

    # Reload skills
    load()

    {:ok, get(name)}
  end

  defp save_script_skill(skill_dir, name, description, code, parameters, allowed_tools) do
    # Save the script
    script_file = Path.join(skill_dir, "script.sh")
    File.write!(script_file, code)
    File.chmod(script_file, 0o755)

    # Save metadata
    save_skill_metadata(skill_dir, name, description, "script", parameters, allowed_tools)

    # Reload skills
    load()

    {:ok, get(name)}
  end

  defp save_mcp_skill(skill_dir, name, description, code, parameters, allowed_tools) do
    # Save MCP config
    config_file = Path.join(skill_dir, "mcp.json")
    File.write!(config_file, code)

    # Save metadata
    save_skill_metadata(skill_dir, name, description, "mcp", parameters, allowed_tools)

    # Reload skills
    load()

    {:ok, get(name)}
  end

  defp save_markdown_skill(skill_dir, name, description, content, parameters, allowed_tools) do
    # Save SKILL.md
    skill_file = Path.join(skill_dir, "SKILL.md")

    frontmatter = """
    ---
    name: #{name}
    description: #{description}
    type: markdown
    user-invocable: true
    ---

    #{content}
    """

    File.write!(skill_file, frontmatter)

    # Reload skills
    load()

    {:ok, get(name)}
  end

  defp save_skill_metadata(skill_dir, name, description, type, parameters, allowed_tools) do
    metadata = %{
      "name" => name,
      "description" => description,
      "type" => type,
      "parameters" => parameters,
      "allowed_tools" => allowed_tools,
      "user_invocable" => true
    }

    meta_file = Path.join(skill_dir, "skill.json")
    File.write!(meta_file, Jason.encode!(metadata))
  end
end
