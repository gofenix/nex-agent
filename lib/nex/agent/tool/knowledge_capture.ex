defmodule Nex.Agent.Tool.KnowledgeCapture do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Knowledge

  def name, do: "knowledge_capture"

  def description,
    do:
      "Capture personal knowledge from chat, web pages, and workspace notes, then promote it into durable layers."

  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["capture", "list", "promote"],
            description: "Knowledge action"
          },
          source: %{
            type: "string",
            enum: ["chat_message", "web_page", "workspace_note"],
            description: "Capture source"
          },
          content: %{type: "string", description: "Capture content for chat_message"},
          title: %{type: "string", description: "Optional title"},
          url: %{type: "string", description: "URL for web capture"},
          path: %{type: "string", description: "Workspace-relative note path"},
          capture_id: %{type: "string", description: "Capture ID for promotion"},
          target: %{
            type: "string",
            enum: ["user", "memory", "skill", "project"],
            description: "Promotion target"
          },
          project: %{type: "string", description: "Optional project name"},
          limit: %{type: "integer", description: "How many captures to list"}
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "capture"} = args, ctx) do
    Knowledge.capture(
      Map.take(args, ["source", "content", "title", "url", "path", "project"]),
      workspace_opts(ctx)
    )
  end

  def execute(%{"action" => "list"} = args, ctx) do
    limit = Map.get(args, "limit", 20)
    source = Map.get(args, "source")
    {:ok, %{"captures" => Knowledge.list(workspace_opts(ctx) ++ [limit: limit, source: source])}}
  end

  def execute(%{"action" => "promote", "capture_id" => capture_id, "target" => target}, ctx) do
    Knowledge.promote(capture_id, target, workspace_opts(ctx))
  end

  def execute(%{"action" => action}, _ctx) do
    {:error, "Unsupported knowledge_capture action: #{action}"}
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  defp workspace_opts(ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    if workspace, do: [workspace: workspace], else: []
  end
end
