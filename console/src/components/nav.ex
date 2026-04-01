defmodule NexAgentConsole.Components.Nav do
  use Nex

  @sections [
    %{
      title: "进化层",
      summary: "六层分流：SOUL、USER、MEMORY、SKILL、TOOL、CODE。",
      links: [
        {"/evolution", "分层总览", "先判断变化应该落到哪一层"},
        {"/memory", "认知记忆", "SOUL / USER / MEMORY / HISTORY"},
        {"/skills", "能力层", "SKILL 方法与 TOOL 能力"},
        {"/code", "代码层", "最后一层：热更、diff 与回滚"}
      ]
    },
    %{
      title: "运行证据",
      summary: "运行中的会话、任务和网关只提供证据与操作，不负责定义进化层。",
      links: [
        {"/", "控制台", "当前状态、建议入口与最近变化"},
        {"/sessions", "会话", "按 session 检查消息与 consolidation"},
        {"/tasks", "任务", "scheduled tasks、cron 与执行结果"},
        {"/runtime", "运行时", "gateway、services 与 heartbeat"}
      ]
    }
  ]

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:current_path, "/")
      |> Map.put(:sections, @sections)
      |> Map.put(:current_section, current_section(Map.get(assigns, :current_path, "/")))

    ~H"""
    <nav class="console-nav">
      <div class="console-nav__rail">
        <div class="console-nav__brand">
          <span class="console-nav__eyebrow">NexAgent Console</span>
          <strong>六层进化台</strong>
          <p>控制台先尊重分层，再展示运行时。不是所有变化都该直接落到工具或代码。</p>
        </div>

        <div class="console-nav__section">
          <div class="console-nav__section-head">
            <span class="console-nav__caption">信息架构</span>
            <span class="console-nav__current">{@current_section}</span>
          </div>

          <div class="console-nav__groups">
            <%= for section <- @sections do %>
              <section
                class={"console-nav__group #{if @current_section == section.title, do: "is-active", else: ""}"}
              >
                <header class="console-nav__group-head">
                  <strong>{section.title}</strong>
                  <p>{section.summary}</p>
                </header>

                <div class="console-nav__links">
                  <%= for {href, label, detail} <- section.links do %>
                    <a
                      href={href}
                      class={"console-nav__link #{if @current_path == href, do: "is-active", else: ""}"}
                    >
                      <span class="console-nav__label">{label}</span>
                      <small>{detail}</small>
                    </a>
                  <% end %>
                </div>
              </section>
            <% end %>
          </div>
        </div>

        <div class="console-nav__footer">
          <span>六层分流</span>
          <span>单实例工作区</span>
          <span>HTMX + SSE</span>
        </div>
      </div>
    </nav>
    """
  end

  defp current_section(path) do
    Enum.find_value(@sections, "进化层", fn section ->
      if Enum.any?(section.links, fn {href, _label, _detail} -> href == path end) do
        section.title
      end
    end)
  end
end
