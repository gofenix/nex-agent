defmodule NexAgentConsole.Components.AdminUI do
  use Nex

  alias NexAgentConsole.Components.Nav

  def page_shell(assigns) do
    ~H"""
    <section class="console-page">
      <header class="page-hero">
        <div>
          <p class="page-hero__eyebrow">{@eyebrow}</p>
          <h1>{@title}</h1>
          <p class="page-hero__subtitle">{@subtitle}</p>
        </div>

        <div class="page-hero__meta">
          <span class="status-pill status-pill--live">
            <span class="status-pill__dot"></span>
            <span data-live-summary>等待实时事件</span>
          </span>
          <a class="ghost-link" href="https://github.com/gofenix/nex" target="_blank" rel="noreferrer">
            Built on Nex
          </a>
        </div>
      </header>

      <section
        class="panel-slot"
        hx-get={@panel_path}
        hx-trigger="load, admin-event from:body delay:250ms"
        hx-swap="innerHTML"
      >
        <div class="loading-panel">加载控制台面板...</div>
      </section>
    </section>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="console-shell">
      {Nav.render(%{current_path: @current_path})}
      <main class="console-main">{raw(@inner_content)}</main>
    </div>
    """
  end

  def overview_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card section-card--metrics">
        <div class="metric-grid">
          {metric(%{label: "Pending signals", value: length(@state.pending_signals), tone: "gold"})}
          {metric(%{label: "Runtime packages", value: @state.skills.runtime_package_count, tone: "ink"})}
          {metric(%{label: "Open tasks", value: @state.tasks.open, tone: "green"})}
          {metric(%{label: "Tracked modules", value: @state.code.modules, tone: "rust"})}
        </div>
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Runtime</p>
            <h2>核心服务状态</h2>
          </div>
        </div>
        {services_grid(%{services: @state.runtime.gateway.services || %{}})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Evolution</p>
            <h2>待处理 signals</h2>
          </div>
          <a class="ghost-link" href="/evolution">打开进化台</a>
        </div>
        {signal_list(%{signals: @state.pending_signals})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Sessions</p>
            <h2>最近会话</h2>
          </div>
          <a class="ghost-link" href="/sessions">查看全部</a>
        </div>
        {session_list(%{sessions: @state.recent_sessions, compact: true})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Tasks</p>
            <h2>任务与提醒</h2>
          </div>
          <a class="ghost-link" href="/tasks">打开任务页</a>
        </div>
        {upcoming_list(%{rows: @state.tasks.upcoming})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Live feed</p>
            <h2>最近事件</h2>
          </div>
        </div>
        {event_feed(%{events: @state.recent_events})}
      </section>
    </div>
    """
  end

  def evolution_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Manual</p>
            <h2>触发 evolution cycle</h2>
          </div>
        </div>
        <div class="actions-row">
          <form hx-post="/trigger_cycle" hx-target="#evolution-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">Run manual cycle</button>
          </form>
          <div id="evolution-action-result" class="action-result"></div>
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">SOUL</p>
            <h2>当前原则快照</h2>
          </div>
        </div>
        {code_block(%{content: @state.soul_preview})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">MEMORY</p>
            <h2>长期记忆快照</h2>
          </div>
        </div>
        {code_block(%{content: @state.memory_preview})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Signals</p>
            <h2>待处理列表</h2>
          </div>
        </div>
        {signal_list(%{signals: @state.pending_signals})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Audit</p>
            <h2>进化时间线</h2>
          </div>
        </div>
        {audit_table(%{rows: @state.recent_events})}
      </section>
    </div>
    """
  end

  def skills_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Local</p>
            <h2>本地 skills</h2>
          </div>
        </div>
        {local_skills(%{skills: @state.local_skills})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Runtime</p>
            <h2>runtime packages</h2>
          </div>
        </div>
        {runtime_packages(%{packages: @state.runtime_packages})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Catalog</p>
            <h2>trusted catalog</h2>
          </div>
        </div>
        {catalog_list(%{entries: @state.runtime_catalog})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Lineage</p>
            <h2>进化谱系</h2>
          </div>
        </div>
        {lineage_list(%{events: @state.lineage})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Runs</p>
            <h2>近期 runtime runs</h2>
          </div>
        </div>
        {run_list(%{runs: @state.recent_runs})}
      </section>
    </div>
    """
  end

  def memory_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card section-card--metrics">
        <div class="metric-grid">
          {metric(%{label: "MEMORY bytes", value: @state.memory_bytes, tone: "ink"})}
          {metric(%{label: "HISTORY bytes", value: @state.history_bytes, tone: "rust"})}
          {metric(%{label: "Workspace", value: "1", tone: "gold"})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">MEMORY.md</p>
            <h2>长期记忆</h2>
          </div>
        </div>
        {code_block(%{content: @state.memory_preview})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">HISTORY.md</p>
            <h2>操作历史</h2>
          </div>
        </div>
        {code_block(%{content: @state.history_preview})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">USER.md</p>
            <h2>用户画像</h2>
          </div>
        </div>
        {code_block(%{content: @state.user_preview})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Memory audit</p>
            <h2>相关事件</h2>
          </div>
        </div>
        {audit_table(%{rows: @state.recent_events})}
      </section>
    </div>
    """
  end

  def sessions_panel(assigns) do
    ~H"""
    <div class="sessions-grid">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Sessions</p>
            <h2>会话目录</h2>
          </div>
        </div>
        {session_list(%{sessions: @state.sessions, compact: false})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Inspect</p>
            <h2>会话详情</h2>
          </div>
        </div>

        <div id="sessions-action-result" class="action-result"></div>

        <%= if @state.selected_session do %>
          <div class="actions-row">
            <form hx-post="/consolidate" hx-target="#sessions-action-result" hx-swap="innerHTML">
              <input type="hidden" name="session_key" value={@state.selected_session.key} />
              <button class="action-button action-button--primary" type="submit">Run consolidation</button>
            </form>

            <form
              hx-post="/reset"
              hx-target="#sessions-action-result"
              hx-swap="innerHTML"
              hx-confirm="确认清空这个 session 吗？"
            >
              <input type="hidden" name="session_key" value={@state.selected_session.key} />
              <button class="action-button action-button--danger" type="submit">Reset session</button>
            </form>
          </div>

          <div class="detail-grid">
            {detail_item(%{label: "Key", value: @state.selected_session.key})}
            {detail_item(%{label: "Messages", value: @state.selected_session.total_messages})}
            {detail_item(%{label: "Unconsolidated", value: @state.selected_session.unconsolidated_messages})}
            {detail_item(%{label: "Updated", value: format_timestamp(@state.selected_session.updated_at)})}
          </div>

          <div class="message-log">
            <%= for msg <- @state.selected_session.messages do %>
              <article class="message-log__item">
                <header>
                  <strong>{msg["role"]}</strong>
                  <span>{format_timestamp(msg["timestamp"])}</span>
                </header>
                <p>{msg["content"]}</p>
              </article>
            <% end %>
          </div>
        <% else %>
          {empty_state(%{title: "没有找到 session", body: "先让 agent 跑起来，控制台才有可检查的会话。"})}
        <% end %>
      </section>
    </div>
    """
  end

  def tasks_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card section-card--metrics">
        <div class="metric-grid">
          {metric(%{label: "Open", value: @state.summary.open, tone: "gold"})}
          {metric(%{label: "Completed", value: @state.summary.completed, tone: "green"})}
          {metric(%{label: "Cron jobs", value: length(@state.cron_jobs), tone: "ink"})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Upcoming</p>
            <h2>待办与提醒</h2>
          </div>
        </div>
        {upcoming_list(%{rows: @state.summary.upcoming})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Cron</p>
            <h2>计划任务</h2>
          </div>
        </div>
        <div id="tasks-action-result" class="action-result"></div>
        {cron_table(%{jobs: @state.cron_jobs})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Tasks</p>
            <h2>最近任务记录</h2>
          </div>
        </div>
        {task_table(%{tasks: @state.tasks})}
      </section>
    </div>
    """
  end

  def runtime_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Gateway</p>
            <h2>连接与启停</h2>
          </div>
        </div>
        <div id="runtime-action-result" class="action-result"></div>
        <div class="actions-row">
          <form hx-post="/start_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">Start gateway</button>
          </form>
          <form hx-post="/stop_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--danger" type="submit">Stop gateway</button>
          </form>
        </div>
        <div class="detail-grid">
          {detail_item(%{label: "Status", value: @state.gateway.status})}
          {detail_item(%{label: "Started at", value: format_timestamp(@state.gateway.started_at)})}
          {detail_item(%{label: "Provider", value: get_in(@state.gateway, [:config, :provider])})}
          {detail_item(%{label: "Model", value: get_in(@state.gateway, [:config, :model])})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Heartbeat</p>
            <h2>维护节拍</h2>
          </div>
        </div>
        <div class="detail-grid">
          {detail_item(%{label: "Enabled", value: readable_bool(@state.heartbeat.enabled)})}
          {detail_item(%{label: "Running", value: readable_bool(@state.heartbeat.running)})}
          {detail_item(%{label: "Interval", value: @state.heartbeat.interval})}
        </div>
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Services</p>
            <h2>运行时服务</h2>
          </div>
        </div>
        {services_grid(%{services: @state.gateway.services || %{}})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Workspace</p>
            <h2>工作目录</h2>
          </div>
        </div>
        {directory_list(%{rows: @state.directories})}
      </section>
    </div>
    """
  end

  def code_panel(assigns) do
    ~H"""
    <div class="grid-stack">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Modules</p>
            <h2>可热更模块</h2>
          </div>
        </div>

        <form method="get" action="/code" class="inline-form">
          <label for="module">Current module</label>
          <select id="module" name="module">
            <%= for module <- @state.modules do %>
              <option value={module} selected={module == @state.selected_module}>{module}</option>
            <% end %>
          </select>
          <button class="action-button" type="submit">Load</button>
        </form>

        <div class="code-source-preview">
          {code_block(%{content: @state.current_source_preview})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">Versions</p>
            <h2>版本轨迹</h2>
          </div>
        </div>
        {version_list(%{versions: @state.versions, selected_module: @state.selected_module})}
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Hot upgrade</p>
            <h2>预览 diff 与应用热更</h2>
          </div>
        </div>

        <div id="code-action-result" class="action-result"></div>

        <form class="editor-form">
          <input type="hidden" name="module" value={@state.selected_module} />
          <label for="reason">Reason</label>
          <input id="reason" type="text" name="reason" value="Console hot upgrade" />
          <label for="code">New source</label>
          <textarea id="code" name="code">{@state.current_source}</textarea>

          <div class="actions-row">
            <button
              type="submit"
              class="action-button"
              hx-post="/preview"
              hx-target="#code-action-result"
              hx-swap="innerHTML"
            >
              Preview diff
            </button>

            <button
              type="submit"
              class="action-button action-button--primary"
              hx-post="/hot_upgrade"
              hx-target="#code-action-result"
              hx-swap="innerHTML"
            >
              Apply hot upgrade
            </button>
          </div>
        </form>

        <form class="inline-form" hx-post="/rollback" hx-target="#code-action-result" hx-swap="innerHTML">
          <input type="hidden" name="module" value={@state.selected_module} />
          <label for="version_id">Rollback target</label>
          <select id="version_id" name="version_id">
            <option value="">Latest previous version</option>
            <%= for version <- @state.versions do %>
              <option value={version.id}>{version.id}</option>
            <% end %>
          </select>
          <button class="action-button action-button--danger" type="submit">Rollback</button>
        </form>
      </section>

      <section class="section-card section-card--wide">
        <div class="section-head">
          <div>
            <p class="section-kicker">Audit</p>
            <h2>最近 code events</h2>
          </div>
        </div>
        {audit_table(%{rows: @state.recent_events})}
      </section>
    </div>
    """
  end

  def notice(assigns) do
    ~H"""
    <article class={"notice notice--#{@tone}"}>
      <strong>{@title}</strong>
      <p>{@body}</p>
    </article>
    """
  end

  def diff_preview(assigns) do
    ~H"""
    <section class="diff-preview">
      <header class="diff-preview__head">
        <p class="section-kicker">Preview</p>
        <h3>{@module}</h3>
      </header>
      {code_block(%{content: @diff})}
    </section>
    """
  end

  defp metric(assigns) do
    ~H"""
    <article class={"metric-card metric-card--#{@tone}"}>
      <span class="metric-card__label">{@label}</span>
      <strong class="metric-card__value">{@value}</strong>
    </article>
    """
  end

  defp services_grid(assigns) do
    ~H"""
    <div class="service-grid">
      <%= for {name, alive} <- Enum.sort(@services) do %>
        <article class="service-chip">
          <span>{name}</span>
          <span class={"status-pill #{if alive, do: "status-pill--ok", else: "status-pill--dead"}"}>
            {if alive, do: "up", else: "down"}
          </span>
        </article>
      <% end %>
    </div>
    """
  end

  defp signal_list(assigns) do
    ~H"""
    <%= if @signals == [] do %>
      {empty_state(%{title: "目前没有 pending signals", body: "这通常意味着最近的自我修正已被整理进记忆或进化流程。"})}
    <% else %>
      <div class="stack-list">
        <%= for signal <- @signals do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(signal, "source", "unknown")}</strong>
            </header>
            <p>{Map.get(signal, "signal", "")}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp session_list(assigns) do
    ~H"""
    <%= if @sessions == [] do %>
      {empty_state(%{title: "还没有 session", body: "先通过聊天入口或手工 prompt 跑一次 agent。"})}
    <% else %>
      <div class="stack-list">
        <%= for session <- @sessions do %>
          <a class="stack-list__item" href={"/sessions?session_key=#{URI.encode(session.key)}"}>
            <header>
              <strong>{session.key}</strong>
              <span>{session.total_messages} msgs</span>
            </header>
            <p>{session.last_message || "No messages yet"}</p>
          </a>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp upcoming_list(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "没有即将到来的提醒", body: "当前没有待触发的任务或 follow-up。"})}
    <% else %>
      <div class="stack-list">
        <%= for row <- @rows do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(row, "title")}</strong>
              <span>{Map.get(row, "status")}</span>
            </header>
            <p>{Map.get(row, "summary") || "No summary"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp event_feed(assigns) do
    ~H"""
    <div class="event-feed">
      <%= for event <- @events do %>
        <article class="event-feed__item">
          <header>
            <span class="status-pill">{event["topic"]}</span>
            <time>{format_timestamp(event["timestamp"])}</time>
          </header>
          <strong>{event["summary"]}</strong>
          <p>{event["kind"]}</p>
        </article>
      <% end %>
    </div>
    """
  end

  defp audit_table(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "暂无审计事件", body: "相关动作发生后会在这里出现。"})}
    <% else %>
      <div class="audit-table">
        <%= for row <- @rows do %>
          <article class="audit-table__row">
            <time>{format_timestamp(Map.get(row, "timestamp"))}</time>
            <strong>{Map.get(row, "event")}</strong>
            <p>{inspect(Map.get(row, "payload", %{}), pretty: true)}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp local_skills(assigns) do
    ~H"""
    <%= if @skills == [] do %>
      {empty_state(%{title: "没有检测到本地 skills", body: "skills 目录为空时，这里不会渲染任何条目。"})}
    <% else %>
      <div class="stack-list">
        <%= for skill <- @skills do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(skill, :name) || Map.get(skill, "name")}</strong>
            </header>
            <p>{Map.get(skill, :description) || Map.get(skill, "description")}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp runtime_packages(assigns) do
    ~H"""
    <%= if @packages == [] do %>
      {empty_state(%{title: "runtime packages 为空", body: "skill runtime 还没有成功安装或索引任何 package。"})}
    <% else %>
      <div class="stack-list">
        <%= for package <- @packages do %>
          <article class="stack-list__item">
            <header>
              <strong>{package["name"]}</strong>
              <span>{package["execution_mode"]}</span>
            </header>
            <p>{get_in(package, ["manifest", "description"]) || "No description"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp catalog_list(assigns) do
    ~H"""
    <%= if @entries == [] do %>
      {empty_state(%{title: "catalog 为空", body: "skill runtime 还没有同步 trusted GitHub catalog。"})}
    <% else %>
      <div class="stack-list">
        <%= for entry <- Enum.take(@entries, 20) do %>
          <article class="stack-list__item">
            <header>
              <strong>{entry.name}</strong>
              <span>{entry.source_id}</span>
            </header>
            <p>{entry.description || "No description"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp lineage_list(assigns) do
    ~H"""
    <%= if @events == [] do %>
      {empty_state(%{title: "还没有 lineage events", body: "capture / evolve 之后这里会开始积累谱系。"})}
    <% else %>
      <div class="audit-table">
        <%= for event <- @events do %>
          <article class="audit-table__row">
            <time>{format_timestamp(event["created_at"])}</time>
            <strong>{event["kind"]}</strong>
            <p>{event["summary"]}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp run_list(assigns) do
    ~H"""
    <%= if @runs == [] do %>
      {empty_state(%{title: "暂无 runtime runs", body: "开启 skill runtime 后，执行轨迹会在这里出现。"})}
    <% else %>
      <div class="audit-table">
        <%= for run <- @runs do %>
          <article class="audit-table__row">
            <time>{format_timestamp(run.inserted_at)}</time>
            <strong>{run.run_id}</strong>
            <p>{run.prompt || "No prompt preview"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp task_table(assigns) do
    ~H"""
    <%= if @tasks == [] do %>
      {empty_state(%{title: "没有任务记录", body: "任务工具开始使用后，这里会展示完整任务列表。"})}
    <% else %>
      <div class="audit-table">
        <%= for task <- Enum.take(@tasks, 30) do %>
          <article class="audit-table__row">
            <time>{format_timestamp(task["updated_at"])}</time>
            <strong>{task["title"]}</strong>
            <p>{task["status"]} · {task["summary"] || "No summary"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp cron_table(assigns) do
    ~H"""
    <%= if @jobs == [] do %>
      {empty_state(%{title: "没有 cron jobs", body: "定时任务创建后，这里会出现启停和手动执行入口。"})}
    <% else %>
      <div class="cron-table">
        <%= for job <- @jobs do %>
          <article class="cron-table__row">
            <div>
              <strong>{job.name}</strong>
              <p>{inspect(job.schedule)}</p>
            </div>
            <div class="actions-row">
              <form hx-post="/run_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                <input type="hidden" name="job_id" value={job.id} />
                <button class="micro-button" type="submit">Run</button>
              </form>

              <%= if job.enabled do %>
                <form hx-post="/disable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                  <input type="hidden" name="job_id" value={job.id} />
                  <button class="micro-button micro-button--danger" type="submit">Disable</button>
                </form>
              <% else %>
                <form hx-post="/enable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                  <input type="hidden" name="job_id" value={job.id} />
                  <button class="micro-button micro-button--ok" type="submit">Enable</button>
                </form>
              <% end %>
            </div>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp directory_list(assigns) do
    ~H"""
    <div class="directory-grid">
      <%= for row <- @rows do %>
        <article class="service-chip">
          <span>{row.name}</span>
          <span class={"status-pill #{if row.exists, do: "status-pill--ok", else: "status-pill--dead"}"}>
            {if row.exists, do: "present", else: "missing"}
          </span>
        </article>
      <% end %>
    </div>
    """
  end

  defp version_list(assigns) do
    ~H"""
    <%= if @versions == [] do %>
      {empty_state(%{title: "还没有 code versions", body: "第一次热更成功后，这里会出现版本轨迹。"})}
    <% else %>
      <div class="audit-table">
        <%= for version <- @versions do %>
          <article class="audit-table__row">
            <time>{version.timestamp}</time>
            <strong>{version.id}</strong>
            <p>{@selected_module}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp detail_item(assigns) do
    ~H"""
    <article class="detail-item">
      <span>{@label}</span>
      <strong>{@value}</strong>
    </article>
    """
  end

  defp code_block(assigns) do
    ~H"""
    <pre class="code-block"><code>{@content || "(empty)"}</code></pre>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <article class="empty-state">
      <strong>{@title}</strong>
      <p>{@body}</p>
    </article>
    """
  end

  defp format_timestamp(nil), do: "n/a"
  defp format_timestamp(""), do: "n/a"

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> "n/a"
  end

  defp format_timestamp(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_timestamp(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  defp format_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _ -> value
    end
  end

  defp readable_bool(true), do: "yes"
  defp readable_bool(false), do: "no"
  defp readable_bool(nil), do: "n/a"
  defp readable_bool(value), do: to_string(value)
end
