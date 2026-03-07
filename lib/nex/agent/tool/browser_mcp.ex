defmodule Nex.Agent.Tool.BrowserMCP do
  @moduledoc """
  Browser automation via MCP (Model Context Protocol).
  
  Controls browser through @browsermcp/mcp server.
  Requires Browser MCP Chrome extension to be installed.
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  alias Nex.Agent.MCP

  @mcp_command "npx"
  @mcp_args ["-y", "@browsermcp/mcp"]

  # Tool metadata
  @impl true
  def name, do: "browser"

  @impl true
  def description, do: "Control browser via MCP - navigate, click, type, screenshot"

  @impl true
  def category, do: :skill

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        required: ["action"],
        properties: %{
          action: %{
            type: "string",
            enum: ["navigate", "click", "type", "screenshot", "evaluate", "get_content"],
            description: "Browser action to perform"
          },
          url: %{
            type: "string",
            description: "URL for navigate action"
          },
          selector: %{
            type: "string",
            description: "CSS selector for click/type actions"
          },
          text: %{
            type: "string",
            description: "Text to type"
          },
          script: %{
            type: "string",
            description: "JavaScript code for evaluate action"
          }
        }
      }
    }
  end

  @impl true
  def execute(args, _context) do
    action = args["action"]
    
    Logger.info("[BrowserMCP] Executing action: #{action}")
    
    with {:ok, conn} <- ensure_connection(),
         {:ok, result} <- do_action(conn, action, args) do
      {:ok, result}
    else
      {:error, reason} ->
        Logger.error("[BrowserMCP] Action failed: #{inspect(reason)}")
        {:error, "Browser action failed: #{inspect(reason)}"}
    end
  end

  # Private functions

  defp ensure_connection do
    # Start a new MCP connection
    case MCP.start_link(command: @mcp_command, args: @mcp_args) do
      {:ok, conn} ->
        case MCP.initialize(conn) do
          :ok -> {:ok, conn}
          {:error, reason} -> {:error, "Failed to initialize MCP: #{reason}"}
        end
      {:error, reason} ->
        {:error, "Failed to start MCP: #{inspect(reason)}"}
    end
  end

  defp do_action(conn, "navigate", args) do
    url = args["url"] || "https://twitter.com"
    MCP.call_tool(conn, "browser_navigate", %{"url" => url})
  end

  defp do_action(conn, "click", args) do
    selector = args["selector"] || ""
    if selector == "" do
      {:error, "selector is required for click action"}
    else
      MCP.call_tool(conn, "browser_click", %{"selector" => selector})
    end
  end

  defp do_action(conn, "type", args) do
    selector = args["selector"] || ""
    text = args["text"] || ""
    
    if selector == "" or text == "" do
      {:error, "both selector and text are required for type action"}
    else
      MCP.call_tool(conn, "browser_type", %{"selector" => selector, "text" => text})
    end
  end

  defp do_action(conn, "screenshot", _args) do
    MCP.call_tool(conn, "browser_screenshot", %{})  
  end

  defp do_action(conn, "evaluate", args) do
    script = args["script"] || ""
    if script == "" do
      {:error, "script is required for evaluate action"}
    else
      MCP.call_tool(conn, "browser_evaluate", %{"script" => script})
    end
  end

  defp do_action(conn, "get_content", _args) do
    MCP.call_tool(conn, "browser_get_content", %{})  
  end

  defp do_action(_conn, action, _args) do
    {:error, "Unknown action: #{action}"}
  end
end
