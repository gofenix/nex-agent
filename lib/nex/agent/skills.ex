defmodule Nex.Agent.Skills do
  @moduledoc """
  Skills registry and execution.

  ## Usage

      # Load all skills
      :ok = Nex.Agent.Skills.load()
      
      # List available skills
      skills = Nex.Agent.Skills.list()
      
      # Execute a skill
      {:ok, result} = Nex.Agent.Skills.execute("explain-code", "some arguments")
      
      # Execute with context (for fork mode)
      {:ok, result} = Nex.Agent.Skills.execute("deploy", "production", context: :fork)
  """

  use Agent

  @name __MODULE__

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
  Execute a skill.

  ## Options

  * `:context` - `:inline` (default) or `:fork`
  * `:tools` - List of allowed tools (overrides skill's allowed_tools)

  ## Examples

      Nex.Agent.Skills.execute("explain-code", "how does this work?")
      Nex.Agent.Skills.execute("deploy", "production", context: :fork)
  """
  @spec execute(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(name, arguments, opts \\ []) do
    skill = get(name)

    if skill do
      # Check if model invocation is disabled
      if skill.disable_model_invocation && Keyword.get(opts, :invoked_by, :user) == :model do
        {:error, "Skill #{name} is disabled for model invocation"}
      else
        execute_skill(skill, arguments, opts)
      end
    else
      {:error, "Skill #{name} not found"}
    end
  end

  @doc """
  Format skills for LLM function calling.
  """
  @spec for_llm() :: list(map())
  def for_llm do
    # Ensure Skills agent is started
    unless Process.whereis(@name), do: start_link()

    list()
    |> Enum.filter(& &1.user_invocable)
    |> Enum.map(fn skill ->
      %{
        name: skill.name,
        description: skill.description,
        input_schema: %{
          type: "object",
          properties: %{
            arguments: %{
              type: "string",
              description: skill.argument_hint || "Arguments for the skill"
            }
          },
          required: ["arguments"]
        }
      }
    end)
  end

  # Private functions

  defp execute_skill(skill, arguments, opts) do
    context = Keyword.get(opts, :context, :inline)

    case context do
      :fork ->
        # Execute in a separate context (subagent)
        execute_in_fork(skill, arguments, opts)

      :inline ->
        # Execute inline - substitute arguments in content
        execute_inline(skill, arguments)
    end
  end

  defp execute_inline(skill, arguments) do
    content = substitute_arguments(skill.content, arguments)

    {:ok, content}
  end

  defp execute_in_fork(skill, arguments, opts) do
    # For fork context, return the skill content for the subagent to use
    content = substitute_arguments(skill.content, arguments)

    # Return formatted for subagent use
    {:ok,
     %{
       content: content,
       agent: skill.agent || "general-purpose",
       tools: opts[:tools] || skill.allowed_tools || []
     }}
  end

  defp substitute_arguments(content, arguments) do
    content
    |> String.replace("$ARGUMENTS", arguments)
    |> String.replace("$0", arguments)
    |> String.replace("$ARGUMENTS[0]", arguments)

    # Replace $1, $2, etc. - would need proper parsing for multiple args
    # For now, just handle $ARGUMENTS
  end
end
