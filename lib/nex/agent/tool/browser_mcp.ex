defmodule Nex.Agent.Tool.BrowserMCP do
  @moduledoc """
  Browser automation via MCP (Model Context Protocol).

  Controls browser through @browsermcp/mcp server.
  Requires Browser MCP Chrome extension to be installed.

  Uses ServerManager for persistent connections — the browser MCP server
  stays alive across tool calls, enabling multi-step browser automation.
  """

  @behaviour Nex.Agent.Tool.Behaviour
  require Logger

  alias Nex.Agent.MCP.ServerManager

  @server_name "browser"
  @mcp_args ["-y", "@browsermcp/mcp"]

  # Tool metadata
  @impl true
  def name, do: "browser"

  @impl true
  def description do
    "Control browser directly - navigate, click, type, screenshot, snapshot. " <>
      "Manages MCP connection automatically (do NOT start npx or MCP servers manually via bash)."
  end

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
              description: "Browser action. Just call this tool directly — connection is managed automatically."
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

    with {:ok, server_id} <- ensure_connection(),
         {:ok, result} <- do_action(server_id, action, args) do
      {:ok, result}
    else
      {:error, reason} ->
        Logger.error("[BrowserMCP] Action failed: #{inspect(reason)}")
        {:error, "Browser action failed: #{inspect(reason)}"}
    end
  end

  # Private functions

  defp ensure_connection do
    case ServerManager.get_by_name(@server_name) do
      {:ok, server_id} ->
        {:ok, server_id}

      :error ->
        case System.find_executable("npx") do
          nil ->
            {:error, "npx not found in PATH"}

          npx_path ->
            ServerManager.start(@server_name, command: npx_path, args: @mcp_args)
        end
    end
  end

  defp do_action(server_id, "navigate", args) do
    url = args["url"] || "https://twitter.com"
    ServerManager.call_tool(server_id, "browser_navigate", %{"url" => url})
  end

  defp do_action(server_id, "click", args) do
    selector = args["selector"] || ""
    element = args["element"] || ""

    if selector != "" do
      ServerManager.call_tool(server_id, "browser_click", %{"selector" => selector})
    else
      ServerManager.call_tool(server_id, "browser_click", %{"element" => element})
    end
  end

  defp do_action(server_id, "type", args) do
    selector = args["selector"] || ""
    element = args["element"] || ""
    text = args["text"] || ""

    params = %{
      "text" => text,
      "submit" => false
    }

    params =
      if selector != "" do
        Map.put(params, "selector", selector)
      else
        Map.put(params, "element", element)
      end

    ServerManager.call_tool(server_id, "browser_type", params)
  end

  defp do_action(server_id, "screenshot", _args) do
    ServerManager.call_tool(server_id, "browser_screenshot", %{})
  end

  defp do_action(server_id, "snapshot", _args) do
    ServerManager.call_tool(server_id, "browser_snapshot", %{})
  end

  defp do_action(server_id, "go_back", _args) do
    ServerManager.call_tool(server_id, "browser_go_back", %{})
  end

  defp do_action(server_id, "go_forward", _args) do
    ServerManager.call_tool(server_id, "browser_go_forward", %{})
  end

  defp do_action(server_id, "wait", args) do
    ms = args["milliseconds"] || 1000
    ServerManager.call_tool(server_id, "browser_wait", %{"milliseconds" => ms})
  end

  defp do_action(_server_id, action, _args) do
    {:error, "Unknown action: #{action}"}
  end
end
