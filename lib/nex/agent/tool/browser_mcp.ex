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
  def description, do: "Control browser via MCP - navigate, click, type, screenshot, etc."

  @impl true
  def category, do: :skill

  @impl true
  def definition do
    %{
      type: "function",
      function: %{
        name: name(),
        description: description(),
        parameters: %{
          type: "object",
          required: ["action"],
          properties: %{
            action: %{
              type: "string",
              enum: ["navigate", "click", "type", "screenshot", "snapshot", "go_back", "go_forward", "wait"],
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
            element: %{
              type: "string",
              description: "Element reference from snapshot"
            },
            milliseconds: %{
              type: "integer",
              description: "Wait time in milliseconds"
            }
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
      MCP.stop(conn)
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
    element = args["element"] || ""
    
    if selector != "" do
      MCP.call_tool(conn, "browser_click", %{"selector" => selector})
    else
      MCP.call_tool(conn, "browser_click", %{"element" => element})
    end
  end

  defp do_action(conn, "type", args) do
    selector = args["selector"] || ""
    element = args["element"] || ""
    text = args["text"] || ""
    
    params = %{
      "text" => text,
      "submit" => false
    }
    
    params = if selector != "" do
      Map.put(params, "selector", selector)
    else
      Map.put(params, "element", element)
    end
    
    MCP.call_tool(conn, "browser_type", params)
  end

  defp do_action(conn, "screenshot", _args) do
    MCP.call_tool(conn, "browser_screenshot", %{})  
  end

  defp do_action(conn, "snapshot", _args) do
    MCP.call_tool(conn, "browser_snapshot", %{})  
  end

  defp do_action(conn, "go_back", _args) do
    MCP.call_tool(conn, "browser_go_back", %{})  
  end

  defp do_action(conn, "go_forward", _args) do
    MCP.call_tool(conn, "browser_go_forward", %{})  
  end

  defp do_action(conn, "wait", args) do
    ms = args["milliseconds"] || 1000
    MCP.call_tool(conn, "browser_wait", %{"milliseconds" => ms})  
  end

  defp do_action(_conn, action, _args) do
    {:error, "Unknown action: #{action}"}
  end
end
