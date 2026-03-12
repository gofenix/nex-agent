defmodule Nex.Agent.Tool.SoulUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "soul_update"

  def description,
    do: "Update your SOUL.md identity and principle file in the configured workspace root."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "New full content for SOUL.md"}
        },
        required: ["content"]
      }
    }
  end

  def execute(%{"content" => content}, _ctx) do
    workspace =
      Application.get_env(
        :nex_agent,
        :workspace_path,
        Path.join(System.get_env("HOME", "."), ".nex/agent/workspace")
      )

    soul_path = Path.join(workspace, "SOUL.md")

    dir = Path.dirname(soul_path)
    File.mkdir_p!(dir)

    case File.write(soul_path, content) do
      :ok -> {:ok, "SOUL.md updated successfully."}
      {:error, reason} -> {:error, "Error updating SOUL.md: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "content is required"}
end
