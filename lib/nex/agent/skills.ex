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

  alias Nex.Agent.{Skills.Loader, Workspace}
  alias Nex.SkillRuntime.{Frontmatter, Package, Registry}

  @name __MODULE__
  @draft_prefix "[Draft] "
  @draft_status_regex ~r/\A\s*<!--\s*status:\s*draft\b.*?-->\s*/s

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts ++ [name: @name])
  end

  @spec load() :: :ok
  def load do
    unless Process.whereis(@name), do: start_link()

    skills = Loader.load_all()

    Agent.update(@name, fn _state ->
      Enum.into(skills, %{}, fn skill -> {skill.name, skill} end)
    end)

    :ok
  end

  @spec reload() :: :ok
  def reload, do: load()

  @spec list(keyword()) :: list(map())
  def list(opts \\ []) do
    if Keyword.has_key?(opts, :workspace) do
      opts
      |> Loader.load_all()
      |> Enum.sort_by(&to_string(skill_name(&1)))
    else
      list_cached()
    end
  end

  defp list_cached do
    unless Process.whereis(@name), do: start_link()
    Agent.get(@name, &Map.values/1)
  end

  @spec get(String.t(), keyword()) :: map() | nil
  def get(name, opts \\ []) do
    if Keyword.has_key?(opts, :workspace) do
      Enum.find(list(opts), &(to_string(skill_name(&1)) == name))
    else
      unless Process.whereis(@name), do: start_link()
      Agent.get(@name, &Map.get(&1, name))
    end
  end

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def create(attrs, opts \\ []) do
    name = attrs["name"] || attrs[:name]
    description = attrs["description"] || attrs[:description] || ""
    content = attrs["content"] || attrs[:content] || attrs["code"] || attrs[:code] || ""
    parameters = attrs["parameters"] || attrs[:parameters] || %{}
    allowed_tools = attrs["allowed_tools"] || attrs[:allowed_tools] || []
    type = attrs["type"] || attrs[:type]
    user_invocable = user_invocable_attr(attrs)

    cond do
      is_nil(name) ->
        {:error, "Skill name is required"}

      type in ["elixir", "script", "mcp"] ->
        {:error,
         "Unsupported skill type. Skills are Markdown-only; implement code-based capabilities as tools."}

      true ->
        save_markdown_skill(
          name,
          description,
          content,
          parameters,
          allowed_tools,
          user_invocable,
          opts
        )
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, String.t()}
  def delete(name, opts \\ []) do
    with :ok <- validate_skill_name(name) do
      skill_dir = Path.join(skills_dir(opts), name)

      if File.exists?(skill_dir) do
        File.rm_rf!(skill_dir)

        if Process.whereis(@name) and not Keyword.has_key?(opts, :workspace) do
          Agent.update(@name, &Map.delete(&1, name))
        end

        :ok
      else
        {:error, "Skill not found: #{name}"}
      end
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

    case get(name, opts) do
      nil ->
        {:error, "Skill not found: #{name}"}

      skill ->
        cond do
          draft?(skill) ->
            {:error, "Skill #{name} is still draft-only; publish it from the console before use"}

          skill.disable_model_invocation && Keyword.get(opts, :invoked_by, :user) == :model ->
          {:error, "Skill #{name} is disabled for model invocation"}

          true ->
            execute_markdown_skill(skill, args, opts)
        end
    end
  end

  @spec for_llm(keyword()) :: list(map())
  def for_llm(opts \\ []) do
    list(opts)
    |> Enum.filter(& &1.user_invocable)
    |> Enum.map(fn skill ->
      %{
        "name" => skill.name,
        "description" => skill.description,
        "path" => skill.path
      }
    end)
  end

  @spec publish_draft(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def publish_draft(name, opts \\ []) when is_binary(name) do
    with %{} = skill <- get(name, opts) || {:error, "Skill not found: #{name}"},
         true <- draft?(skill) || {:error, "Skill is already published"},
         :ok <- publish_draft_files(skill, opts) do
      reload_after_publish(opts)
      {:ok, get(name, opts)}
    end
  end

  @spec draft?(map()) :: boolean()
  def draft?(skill) when is_map(skill) do
    draft_value = Map.get(skill, :draft) || Map.get(skill, "draft")
    description = Map.get(skill, :description) || Map.get(skill, "description") || ""
    content = Map.get(skill, :content) || Map.get(skill, "content") || ""

    draft_value in [true, "true"] or draft_description?(description) or draft_content?(content)
  end

  @spec strip_draft_prefix(String.t() | nil) :: String.t()
  def strip_draft_prefix(nil), do: ""

  def strip_draft_prefix(description) when is_binary(description) do
    String.replace_prefix(description, @draft_prefix, "")
  end

  @spec always_instructions(keyword()) :: String.t()
  def always_instructions(opts \\ []) do
    opts
    |> list()
    |> Enum.filter(&truthy_skill_field?(&1, :always))
    |> Enum.map_join("\n\n---\n\n", &format_always_skill/1)
  end

  @doc """
  Read skill instructions by name, searching workspace skills first then priv/skills/.
  """
  @spec read_skill_instructions(String.t()) :: String.t()
  def read_skill_instructions(name) do
    priv_path = Path.join(:code.priv_dir(:nex_agent), "skills/#{name}/SKILL.md")

    case File.read(priv_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
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

  defp save_markdown_skill(
         name,
         description,
         content,
         parameters,
         allowed_tools,
         user_invocable,
         opts
       ) do
    with :ok <- validate_skill_name(name) do
      skill_dir = Path.join(skills_dir(opts), name)
      skill_file = Path.join(skill_dir, "SKILL.md")

      File.mkdir_p!(skill_dir)

      frontmatter_lines =
        [
          "---",
          "name: #{yaml_scalar(name)}",
          "description: #{yaml_scalar(description)}",
          "user-invocable: #{if(user_invocable, do: "true", else: "false")}"
        ]
        |> maybe_put_frontmatter("parameters", parameters)
        |> maybe_put_frontmatter("allowed-tools", allowed_tools)
        |> Kernel.++(["---", "", content])

      File.write!(skill_file, Enum.join(frontmatter_lines, "\n"))

      if Keyword.has_key?(opts, :workspace) do
        {:ok, get(name, opts)}
      else
        load()
        {:ok, get(name)}
      end
    end
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

  defp skill_name(skill), do: Map.get(skill, :name) || Map.get(skill, "name")

  defp user_invocable_attr(attrs) when is_map(attrs) do
    case Map.get(attrs, "user-invocable") || Map.get(attrs, "user_invocable") ||
           Map.get(attrs, :user_invocable) do
      nil -> true
      value -> value in [true, "true"]
    end
  end

  defp publish_draft_files(skill, opts) do
    skill
    |> draft_paths(opts)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case publish_draft_file(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp draft_paths(skill, opts) do
    local_path =
      Path.join([
        skills_dir(opts),
        skill_name(skill),
        "SKILL.md"
      ])

    runtime_path =
      Path.join([
        skills_dir(opts),
        "rt__#{Package.slugify(skill_name(skill))}",
        "SKILL.md"
      ])

    [local_path, runtime_path, Map.get(skill, :path) || Map.get(skill, "path")]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
  end

  defp publish_draft_file(path) do
    with {:ok, content} <- File.read(path) do
      {frontmatter, body} = Frontmatter.parse_document(content)

      updated_frontmatter =
        frontmatter
        |> Map.put("description", strip_draft_prefix(frontmatter["description"]))
        |> Map.put("user-invocable", true)

      updated_body =
        body
        |> String.trim_leading()
        |> then(&Regex.replace(@draft_status_regex, &1, ""))
        |> String.trim_leading()

      File.write(path, render_skill_file(updated_frontmatter, updated_body))
    else
      {:error, reason} -> {:error, format_file_error(reason)}
    end
  end

  defp render_skill_file(frontmatter, body) do
    lines =
      ["---"] ++
        frontmatter_lines(frontmatter) ++
        ["---", "", String.trim_leading(body), ""]

    Enum.join(lines, "\n")
  end

  defp frontmatter_lines(frontmatter) do
    ordered_keys = [
      "name",
      "description",
      "user-invocable",
      "execution_mode",
      "version",
      "entry_script",
      "disable-model-invocation",
      "always",
      "parameters",
      "allowed-tools",
      "references",
      "requires",
      "context",
      "agent",
      "argument-hint"
    ]

    prioritized =
      ordered_keys
      |> Enum.flat_map(fn key ->
        if Map.has_key?(frontmatter, key), do: frontmatter_entry(key, frontmatter[key]), else: []
      end)

    remaining =
      frontmatter
      |> Map.drop(ordered_keys)
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.flat_map(fn {key, value} -> frontmatter_entry(to_string(key), value) end)

    prioritized ++ remaining
  end

  defp frontmatter_entry(_key, value) when value in [nil, ""], do: []
  defp frontmatter_entry(key, value) when is_map(value), do: ["#{key}:"] ++ to_yaml_lines(value)
  defp frontmatter_entry(key, value) when is_list(value), do: ["#{key}:"] ++ to_yaml_lines(value)
  defp frontmatter_entry(key, value), do: ["#{key}: #{yaml_scalar(value)}"]

  defp reload_after_publish(opts) do
    if Keyword.has_key?(opts, :workspace) do
      Registry.reload(opts)
      :ok
    else
      load()
    end
  rescue
    _ -> :ok
  end

  defp draft_description?(description) when is_binary(description),
    do: String.starts_with?(description, @draft_prefix)

  defp draft_description?(_), do: false

  defp draft_content?(content) when is_binary(content),
    do: Regex.match?(@draft_status_regex, String.trim_leading(content))

  defp draft_content?(_), do: false

  defp format_file_error(%{message: message}) when is_binary(message), do: message
  defp format_file_error(reason), do: inspect(reason)

  defp truthy_skill_field?(skill, key) do
    value = Map.get(skill, key) || Map.get(skill, to_string(key))
    value in [true, "true"]
  end

  defp format_always_skill(skill) do
    name = skill_name(skill)
    description = Map.get(skill, :description) || Map.get(skill, "description") || ""
    content = Map.get(skill, :content) || Map.get(skill, "content") || ""

    """
    ## Always-On Skill (Compatibility): #{name}

    This skill is marked `always: true` in the workspace, so it remains loaded for backward compatibility.
    Prefer on-demand discovery for new skills.

    Description: #{description}

    #{String.trim(content)}
    """
    |> String.trim()
  end

  defp validate_skill_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "Skill name is required"}

      String.contains?(trimmed, ["/", "\\"]) ->
        {:error, "Skill name must not contain path separators"}

      trimmed in [".", ".."] or String.contains?(trimmed, "..") ->
        {:error, "Skill name must not contain path traversal segments"}

      true ->
        :ok
    end
  end

  defp validate_skill_name(_), do: {:error, "Skill name is required"}

  defp skills_dir(opts) do
    Workspace.skills_dir(opts)
  end

  defp escape_yaml_string(value),
    do: inspect(value, binaries: :as_strings, printable_limit: :infinity)
end
