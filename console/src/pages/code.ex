defmodule NexAgentConsole.Pages.Code do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    panel_path =
      case Map.get(params, "module") do
        module when is_binary(module) and module != "" ->
          "/api/admin/panels/code?module=" <> URI.encode_www_form(module)

        _ ->
          "/api/admin/panels/code"
      end

    %{
      title: "NexAgent Console | Code",
      eyebrow: "Code",
      subtitle: "预览 diff、热更内部模块，并回滚到历史版本。",
      current_path: "/code",
      panel_path: panel_path
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def preview(req) do
    case Admin.code_preview(req.body["module"], req.body["code"]) do
      {:ok, payload} ->
        AdminUI.diff_preview(%{module: payload.module, diff: payload.diff})

      {:error, reason} ->
        AdminUI.notice(%{title: "Preview failed", body: reason, tone: "danger"})
    end
  end

  def hot_upgrade(req) do
    module = req.body["module"]
    code = req.body["code"]
    reason = req.body["reason"] || "Console hot upgrade"

    case Admin.hot_upgrade_code(module, code, reason) do
      {:ok, result} ->
        version_id = get_in(result, [:version, :id]) || "ok"

        AdminUI.notice(%{
          title: "Hot upgrade applied",
          body: "#{module} · version #{version_id}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "code", summary: "Hot upgrade applied"})

      {:error, reason} ->
        AdminUI.notice(%{title: "Hot upgrade failed", body: reason, tone: "danger"})
    end
  end

  def rollback(req) do
    case Admin.rollback_code(req.body["module"], req.body["version_id"]) do
      :ok ->
        AdminUI.notice(%{title: "Rollback applied", body: req.body["module"], tone: "warn"})
        |> trigger("admin-event", %{topic: "code", summary: "Rollback applied"})

      {:error, reason} ->
        AdminUI.notice(%{title: "Rollback failed", body: reason, tone: "danger"})
    end
  end
end
