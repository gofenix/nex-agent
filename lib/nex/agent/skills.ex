defmodule Nex.Agent.Skills do
  @moduledoc """
  Markdown-only skills system.

  ## Usage

      :ok = Nex.Agent.Skills.load()
      skills = Nex.Agent.Skills.list()
      {:ok, result} = Nex.Agent.Skills.execute("explain-code", "some arguments")

      {:ok, skill} = Nex.Agent.Skills.create(%{
        name: "todo_add",
        description: "Add a todo item",
        content: "When asked to add a todo item, ..."
      })
  """

  use Agent

  @name __MODULE__
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts ++ [name: @name])
  end

  @spec load() :: :ok
  def load do
    unless Process.whereis(@name), do: start_link()

    skills = Nex.Agent.Skills.Loader.load_all()

    Agent.update(@name, fn _state ->
      Enum.into(skills, %{}, fn skill -> {skill.name, skill} end)
    end)

    :ok
  end

  @spec reload() :: :ok
  def reload, do: load()

  @spec list() :: list(map())
  def list do
    unless Process.whereis(@name), do: start_link()
    Agent.get(@name, &Map.values/1)
  end

  @spec get(String.t()) :: map() | nil
  def get(name) do
    unless Process.whereis(@name), do: start_link()
    Agent.get(@name, &Map.get(&1, name))
  end

  @spec create(map()) :: {:ok, map()} | {:error, String.t()}
  def create(attrs) do
    name = attrs["name"] || attrs[:name]
    description = attrs["description"] || attrs[:description] || ""
    content = attrs["content"] || attrs[:content] || attrs["code"] || attrs[:code] || ""
    parameters = attrs["parameters"] || attrs[:parameters] || %{}
    allowed_tools = attrs["allowed_tools"] || attrs[:allowed_tools] || []
    type = attrs["type"] || attrs[:type]

    cond do
      is_nil(name) ->
        {:error, "Skill name is required"}

      type in ["elixir", "script", "mcp"] ->
        {:error,
         "Unsupported skill type. Skills are Markdown-only; implement code-based capabilities as tools."}

      true ->
        save_markdown_skill(name, description, content, parameters, allowed_tools)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(name) do
    skill_dir = Path.join(skills_dir(), name)

    if File.exists?(skill_dir) do
      File.rm_rf!(skill_dir)

      if Process.whereis(@name) do
        Agent.update(@name, &Map.delete(&1, name))
      end

      :ok
    else
      {:error, "Skill not found: #{name}"}
    end
  end

  @spec execute(String.t(), map() | String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(name, arguments, opts \\ []) do
    args =
      if is_binary(arguments) do
        %{"arguments" => arguments}
      else
        arguments
      end

    case get(name) do
      nil ->
        {:error, "Skill not found: #{name}"}

      skill ->
        if skill.disable_model_invocation && Keyword.get(opts, :invoked_by, :user) == :model do
          {:error, "Skill #{name} is disabled for model invocation"}
        else
          execute_markdown_skill(skill, args, opts)
        end
    end
  end

  @spec for_llm() :: list(map())
  def for_llm do
    unless Process.whereis(@name), do: start_link()

    list()
    |> Enum.filter(& &1.user_invocable)
    |> Enum.map(fn skill ->
      sanitized = skill.name |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

      input_schema =
        case skill.parameters do
          params when is_map(params) and map_size(params) > 0 ->
            %{
              "type" => "object",
              "properties" => params,
              "required" => Map.keys(params)
            }

          _ ->
            %{
              "type" => "object",
              "properties" => %{
                "input" => %{"type" => "string", "description" => "Input to skill"}
              },
              "required" => ["input"]
            }
        end

      %{
        "name" => "skill_#{sanitized}",
        "description" => skill.description,
        "input_schema" => input_schema
      }
    end)
  end

  defp execute_markdown_skill(skill, arguments, opts) do
    content = substitute_arguments(skill.content, arguments)

    case Keyword.get(opts, :context, :inline) do
      :fork ->
        {:ok,
         %{
           content: content,
           agent: skill.agent || "general-purpose",
           tools: skill.allowed_tools || []
         }}

      :inline ->
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

  defp save_markdown_skill(name, description, content, parameters, allowed_tools) do
    skill_dir = Path.join(skills_dir(), name)
    skill_file = Path.join(skill_dir, "SKILL.md")

    File.mkdir_p!(skill_dir)

    frontmatter_lines =
      [
        "---",
        "name: #{yaml_scalar(name)}",
        "description: #{yaml_scalar(description)}",
        "user-invocable: true"
      ]
      |> maybe_put_frontmatter("parameters", parameters)
      |> maybe_put_frontmatter("allowed-tools", allowed_tools)
      |> Kernel.++(["---", "", content])

    File.write!(skill_file, Enum.join(frontmatter_lines, "\n"))

    load()
    {:ok, get(name)}
  end

  defp maybe_put_frontmatter(lines, _key, value) when value in [%{}, [], nil], do: lines

  defp maybe_put_frontmatter(lines, key, value) do
    lines ++ ["#{key}:"] ++ to_yaml_lines(value)
  end

  defp to_yaml_lines(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      case value do
        inner when is_map(inner) ->
          ["  #{key}:"] ++ Enum.map(to_yaml_lines(inner), &"  #{&1}")

        _ ->
          ["  #{key}: #{yaml_scalar(value)}"]
      end
    end)
  end

  defp to_yaml_lines(list) when is_list(list) do
    Enum.map(list, fn item -> "  - #{yaml_scalar(item)}" end)
  end

  defp yaml_scalar(value) when is_binary(value), do: escape_yaml_string(value)
  defp yaml_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value), do: inspect(value)

  defp skills_dir do
    workspace =
      Application.get_env(
        :nex_agent,
        :workspace_path,
        Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")
      )

    Path.join(workspace, "skills")
  end

  defp escape_yaml_string(value),
    do: inspect(value, binaries: :as_strings, printable_limit: :infinity)
end
