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
      title: "NexAgent Console | 代码层",
      subtitle: "代码层是最后一层：只有高层不能解决时，才应该进入这里预览 diff、热更和回滚。",
      current_path: "/code",
      panel_path: panel_path,
      primary_action_label: "回到六层",
      primary_action_href: "/evolution"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def preview(req) do
    case Admin.code_preview(req.body["module"], req.body["code"]) do
      {:ok, payload} ->
        AdminUI.diff_preview(%{module: payload.module, diff: payload.diff})

      {:error, reason} ->
        AdminUI.notice(%{title: "预览失败", body: reason, tone: "danger"})
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
          title: "热更已应用",
          body: "#{module} · version #{version_id}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "code", summary: "Hot upgrade applied"})

      {:error, reason} ->
        AdminUI.notice(%{title: "热更失败", body: reason, tone: "danger"})
    end
  end

  def rollback(req) do
    case Admin.rollback_code(req.body["module"], req.body["version_id"]) do
      :ok ->
        AdminUI.notice(%{title: "回滚已应用", body: req.body["module"], tone: "warn"})
        |> trigger("admin-event", %{topic: "code", summary: "Rollback applied"})

      {:error, reason} ->
        AdminUI.notice(%{title: "回滚失败", body: reason, tone: "danger"})
    end
  end
end
