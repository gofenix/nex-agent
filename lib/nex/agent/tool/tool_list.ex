defmodule Nex.Agent.Tool.ToolList do
  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Action.Code
  alias Nex.Agent.Tool.CustomTools
  alias Nex.Agent.Tool.Registry

  def name, do: "tool_list"
  def description, do: "List built-in and custom tools, or inspect a specific tool."
  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          scope: %{
            type: "string",
            enum: ["builtin", "custom", "all"],
            description: "Which tool scope to list",
            default: "all"
          },
          detail: %{type: "string", description: "Tool name to inspect"}
        }
      }
    }
  end

  def execute(%{"detail" => tool_name}, _ctx) when is_binary(tool_name) and tool_name != "" do
    case custom_detail(tool_name) || builtin_detail(tool_name) do
      nil -> {:error, "Tool not found: #{tool_name}"}
      detail -> {:ok, detail}
    end
  end

  def execute(%{"scope" => scope}, _ctx) when scope in ["builtin", "custom", "all"] do
    {:ok,
     %{
       scope: scope,
       builtin: if(scope in ["builtin", "all"], do: builtin_list(), else: []),
       custom: if(scope in ["custom", "all"], do: custom_list(), else: [])
     }}
  end

  def execute(_args, ctx), do: execute(%{"scope" => "all"}, ctx)

  defp builtin_list do
    custom_names = MapSet.new(Enum.map(custom_list(), & &1["name"]))

    Registry.list()
    |> Enum.reject(&MapSet.member?(custom_names, &1))
    |> Enum.sort()
    |> Enum.map(fn name ->
      module = Registry.get(name)

      %{
        "name" => name,
        "scope" => "builtin",
        "module" => inspect(module),
        "description" => description_for(module),
        "source_path" => if(module, do: Code.source_path(module), else: nil)
      }
    end)
  end

  defp custom_list do
    CustomTools.list()
    |> Enum.map(fn tool ->
      %{
        "name" => tool["name"],
        "scope" => tool["scope"],
        "module" => tool["module"],
        "description" => tool["description"],
        "source_path" => tool.source_path,
        "origin" => tool["origin"]
      }
    end)
  end

  defp builtin_detail(name) do
    custom_names = MapSet.new(Enum.map(custom_list(), & &1["name"]))

    if MapSet.member?(custom_names, name) do
      nil
    else
      case Registry.get(name) do
        nil ->
          nil

        module ->
          %{
            "name" => name,
            "scope" => "builtin",
            "module" => inspect(module),
            "description" => description_for(module),
            "source_path" => Code.source_path(module),
            "definition" => definition_for(module)
          }
      end
    end
  end

  defp custom_detail(name) do
    case CustomTools.detail(name) do
      nil ->
        nil

      tool ->
        %{
          "name" => tool["name"],
          "scope" => tool["scope"],
          "module" => tool["module"],
          "description" => tool["description"],
          "source_path" => tool.source_path,
          "metadata_path" => tool.metadata_path,
          "definition" => tool.definition,
          "created_by" => tool["created_by"],
          "created_at" => tool["created_at"],
          "updated_at" => tool["updated_at"],
          "origin" => tool["origin"]
        }
    end
  end

  defp description_for(module) do
    if is_atom(module) and function_exported?(module, :description, 0),
      do: module.description(),
      else: ""
  end

  defp definition_for(module) do
    if is_atom(module) and function_exported?(module, :definition, 0),
      do: module.definition(),
      else: nil
  end
end
