defmodule NexAgentConsole.Pages.Runtime do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | Runtime",
      eyebrow: "Runtime",
      subtitle: "Gateway、Heartbeat、服务健康与工作区结构。",
      current_path: "/runtime",
      panel_path: "/api/admin/panels/runtime"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def start_gateway(_req) do
    case Admin.start_gateway() do
      :ok ->
        AdminUI.notice(%{title: "Gateway started", body: "runtime is now live", tone: "ok"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway started"})

      {:error, reason} ->
        AdminUI.notice(%{title: "Start failed", body: inspect(reason), tone: "danger"})
    end
  end

  def stop_gateway(_req) do
    case Admin.stop_gateway() do
      :ok ->
        AdminUI.notice(%{title: "Gateway stopped", body: "runtime stopped", tone: "warn"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway stopped"})

      {:error, reason} ->
        AdminUI.notice(%{title: "Stop failed", body: inspect(reason), tone: "danger"})
    end
  end
end
