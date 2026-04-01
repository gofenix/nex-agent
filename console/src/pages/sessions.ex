defmodule NexAgentConsole.Pages.Sessions do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    panel_path =
      case Map.get(params, "session_key") do
        key when is_binary(key) and key != "" ->
          "/api/admin/panels/sessions?session_key=" <> URI.encode_www_form(key)

        _ ->
          "/api/admin/panels/sessions"
      end

    %{
      title: "NexAgent Console | 会话",
      subtitle: "会话页只承载运行证据：看消息、未 consolidation 数量，再决定是否整理或 reset。",
      current_path: "/sessions",
      panel_path: panel_path,
      primary_action_label: "回到六层",
      primary_action_href: "/evolution"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def consolidate(req) do
    session_key = req.body["session_key"]

    case Admin.consolidate_memory(session_key) do
      {:ok, payload} ->
        AdminUI.notice(%{
          title: "Consolidation 已完成",
          body: "#{payload["status"]} · #{payload["reason"]}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "memory", summary: "Memory consolidation finished"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Consolidation 失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end

  def reset(req) do
    session_key = req.body["session_key"]

    case Admin.reset_session(session_key) do
      :ok ->
        AdminUI.notice(%{
          title: "会话已清空",
          body: session_key,
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "sessions", summary: "Session reset"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "清空失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
