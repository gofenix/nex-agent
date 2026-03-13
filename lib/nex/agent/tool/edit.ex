defmodule Nex.Agent.Tool.Edit do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.HotReload
  alias Nex.Agent.Security

  def name, do: "edit"

  def description,
    do:
      "Make surgical edits to files by search and replace. Editing .ex files auto-triggers hot-reload."

  def category, do: :base

  def definition do
    %{
      name: "edit",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          search: %{type: "string", description: "Exact text to find"},
          replace: %{type: "string", description: "Text to replace with"}
        },
        required: ["path", "search", "replace"]
      }
    }
  end

  def execute(%{"path" => path, "search" => search, "replace" => replace}, _ctx) do
    case Security.validate_path(path) do
      {:ok, expanded} ->
        if reserved_profile_shadow_path?(expanded) do
          {:error,
           "USER profile must be edited via user_update or workspace/USER.md. Do not edit workspace/memory/USER.md."}
        else
          case File.read(expanded) do
            {:ok, content} ->
              case String.split(content, search, parts: 2) do
                [_] ->
                  {:error, "Text not found in file: #{expanded}"}

                [prefix, rest] ->
                  new_content = prefix <> replace <> rest

                  case File.write(expanded, new_content) do
                    :ok ->
                      if String.ends_with?(expanded, ".ex") do
                        hot_reload = auto_reload(expanded, new_content)
                        {:ok, %{path: expanded, hot_reload: hot_reload}}
                      else
                        {:ok, "File edited successfully: #{expanded}"}
                      end

                    {:error, reason} ->
                      {:error, "Error writing file #{expanded}: #{inspect(reason)}"}
                  end
              end

            {:error, reason} ->
              {:error, "Error reading file #{expanded}: #{inspect(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path, search, and replace are required"}

  defp reserved_profile_shadow_path?(expanded) do
    Enum.take(Path.split(expanded), -2) == ["memory", "USER.md"]
  end

  defp auto_reload(path, content) do
    HotReload.reload(path, content)
  end
end
