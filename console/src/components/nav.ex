defmodule NexAgentConsole.Components.Nav do
  use Nex

  @links [
    {"/", "总览", "Overview"},
    {"/evolution", "进化", "Evolution"},
    {"/skills", "技能", "Skills"},
    {"/memory", "记忆", "Memory"},
    {"/sessions", "会话", "Sessions"},
    {"/tasks", "任务", "Tasks"},
    {"/runtime", "运行时", "Runtime"},
    {"/code", "代码", "Code"}
  ]

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:current_path, "/")
      |> Map.put(:links, @links)

    ~H"""
    <nav class="console-nav">
      <div class="console-nav__rail">
        <div class="console-nav__brand">
          <span class="console-nav__eyebrow">NexAgent</span>
          <strong>Evolution Console</strong>
        </div>

        <div class="console-nav__links">
          <%= for {href, label, detail} <- @links do %>
            <a
              href={href}
              class={"console-nav__link #{if @current_path == href, do: "is-active", else: ""}"}
            >
              <span>{label}</span>
              <small>{detail}</small>
            </a>
          <% end %>
        </div>

        <div class="console-nav__note">
          <span>单实例</span>
          <span>HTMX + SSE</span>
        </div>
      </div>
    </nav>
    """
  end
end
