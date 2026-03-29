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
      title: "NexAgent Console | Sessions",
      eyebrow: "Sessions",
      subtitle: "检查历史会话、手动 consolidation，并重置单个 session。",
      current_path: "/sessions",
      panel_path: panel_path
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def consolidate(req) do
    session_key = req.body["session_key"]

    case Admin.consolidate_memory(session_key) do
      {:ok, payload} ->
        AdminUI.notice(%{
          title: "Consolidation finished",
          body: "#{payload["status"]} · #{payload["reason"]}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "memory", summary: "Memory consolidation finished"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Consolidation failed",
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
          title: "Session reset",
          body: session_key,
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "sessions", summary: "Session reset"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Reset failed",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
