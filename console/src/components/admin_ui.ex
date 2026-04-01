defmodule NexAgentConsole.Components.AdminUI do
  use Nex

  alias NexAgentConsole.Components.Nav

  @page_meta %{
    "/" => %{name: "控制台", group: "运行证据"},
    "/evolution" => %{name: "分层进化", group: "进化层"},
    "/skills" => %{name: "能力层", group: "进化层"},
    "/memory" => %{name: "认知记忆", group: "进化层"},
    "/sessions" => %{name: "会话", group: "运行证据"},
    "/tasks" => %{name: "任务", group: "运行证据"},
    "/runtime" => %{name: "运行时", group: "运行证据"},
    "/code" => %{name: "代码层", group: "进化层"}
  }

  def page_shell(assigns) do
    path = Map.get(assigns, :current_path)

    assigns =
      assigns
      |> Map.put_new(:page_name, page_name(path))
      |> Map.put_new(:page_group, page_group(path))
      |> Map.put_new(:primary_action_label, nil)
      |> Map.put_new(:primary_action_href, nil)

    ~H"""
    <section class="page-shell">
      <header class="page-header">
        <div class="page-header__main">
          <p class="page-header__eyebrow">{@page_group}</p>
          <div class="page-header__title-row">
            <h1>{@page_name}</h1>
            <span class="page-header__route">{@current_path}</span>
          </div>
          <p class="page-header__subtitle">{@subtitle}</p>
        </div>

        <div class="page-header__meta">
          <span class="status-pill status-pill--live">
            <span class="status-pill__dot"></span>
            <span data-live-summary>等待实时事件</span>
          </span>

          <div class="page-header__actions">
            <%= if @primary_action_href do %>
              <a class="action-button action-button--primary" href={@primary_action_href}>
                {@primary_action_label}
              </a>
            <% end %>

            <a class="ghost-link" href="https://github.com/gofenix/nex" target="_blank" rel="noreferrer">
              基于 Nex
            </a>
          </div>
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
    <div class="console-frame">
      <div class="console-shell">
        {Nav.render(%{current_path: @current_path})}

        <main class="console-main">
          <div class="console-main__inner">{raw(@inner_content)}</div>
        </main>
      </div>
    </div>
    """
  end

  def overview_panel(assigns) do
    ~H"""
    <div class="dashboard-layout dashboard-layout--overview">
      <div class="dashboard-main">
        <section class="section-card section-card--hero">
          <div class="section-head">
            <div>
              <p class="section-kicker">运行总览</p>
              <h2>这里不定义进化层，只回答现在系统处于什么状态</h2>
            </div>
            <a class="ghost-link" href="/evolution">进入六层总览</a>
          </div>

          <p class="section-summary">
            控制台页只保留运行证据与入口分发。分层判断去 `/evolution`，这里负责告诉你现在该先看哪里。
          </p>

          <div class="metric-grid">
            {metric(%{label: "pending signals", value: length(@state.pending_signals), tone: "gold"})}
            {metric(%{label: "open tasks", value: @state.tasks.open, tone: "green"})}
            {metric(%{label: "recent sessions", value: length(@state.recent_sessions), tone: "ink"})}
            {metric(%{label: "gateway services", value: map_size(@state.runtime.gateway.services || %{}), tone: "rust"})}
          </div>
        </section>

        <div class="pair-layout">
          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">当前状态</p>
                <h2>先确认运行是否稳定</h2>
              </div>
            </div>

            <div class="detail-grid">
              {detail_item(%{label: "网关状态", value: @state.runtime.gateway.status})}
              {detail_item(%{label: "Provider", value: get_in(@state.runtime.gateway, [:config, :provider])})}
              {detail_item(%{label: "下一批任务", value: length(@state.tasks.upcoming)})}
              {detail_item(%{label: "最近变化", value: length(@state.recent_events)})}
            </div>

            {services_grid(%{services: @state.runtime.gateway.services || %{}})}
          </section>

          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">建议入口</p>
                <h2>先进入真正拥有该类信息的页面</h2>
              </div>
            </div>

            {workflow_links(%{
              links: [
                %{
                  href: "/evolution",
                  title: "先看六层分流",
                  body: "#{length(@state.pending_signals)} 个信号待处理，先判断它们应落到 SOUL、USER、MEMORY、SKILL、TOOL 还是 CODE。"
                },
                %{
                  href: "/memory",
                  title: "检查认知层",
                  body: "SOUL、USER、MEMORY 和 HISTORY 放在一起看，避免把长期事实和方法混成一页。"
                },
                %{
                  href: "/skills",
                  title: "检查能力层",
                  body: "SKILL 和 TOOL 在这里分开看：前者是方法沉淀，后者是确定性能力。"
                },
                %{
                  href: "/sessions",
                  title: "检查运行证据",
                  body: "如果问题来自单条上下文，就回到 session 详情、消息和 consolidation。"
                }
              ]
            })}
          </section>
        </div>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">最近变化</p>
              <h2>跨层与运行面的最近记录</h2>
            </div>
          </div>

          {event_feed(%{events: Enum.take(@state.recent_events, 6)})}
        </section>
      </div>

      <aside class="dashboard-rail">
        <section class="section-card section-card--accent">
          <div class="section-head">
            <div>
              <p class="section-kicker">分层焦点</p>
              <h2>现在最可能触发进化判断的信号</h2>
            </div>
            <a class="ghost-link" href="/evolution">查看分层</a>
          </div>

          {signal_list(%{signals: Enum.take(@state.pending_signals, 4)})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">最近会话</p>
              <h2>运行证据入口</h2>
            </div>
            <a class="ghost-link" href="/sessions">查看全部</a>
          </div>

          {session_list(%{sessions: Enum.take(@state.recent_sessions, 4), compact: true})}
        </section>
      </aside>
    </div>
    """
  end

  def evolution_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">六层分流</p>
            <h2>先判断变化应该落到哪一层，再决定是否真的进入更重的层</h2>
          </div>
          <span class="status-pill">
            最近事件：{Map.get(List.first(@state.recent_events) || %{}, "event", "暂无相关记录")}
          </span>
        </div>

        <p class="section-summary">
          默认顺序是先稳定高层，再沉淀方法，再扩展能力，最后才修改代码。`/evolution` 应该先回答“该落哪一层”，而不是直接去改实现。
        </p>

        {layer_map(%{layers: @state.layers})}
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">cycle 状态</p>
              <h2>当前是否值得运行下一轮 evolution</h2>
            </div>
          </div>

          <div class="detail-grid">
            {detail_item(%{label: "待处理 signals", value: length(@state.pending_signals)})}
            {detail_item(%{label: "最近相关记录", value: length(@state.recent_events)})}
            {detail_item(%{label: "工作区", value: Path.basename(@state.workspace)})}
          </div>
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">分流原则</p>
              <h2>默认先走高层、轻层、稳定层</h2>
            </div>
          </div>

          {rule_list(%{
            rules: [
              "能写进 USER 或 MEMORY，就不要先写 SKILL。",
              "能沉淀为 SKILL，就不要急着造 TOOL。",
              "能扩展 TOOL，就不要立刻改 CODE。"
            ]
          })}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">pending signals</p>
            <h2>当前待处理变化</h2>
          </div>
        </div>

        {signal_list(%{signals: @state.pending_signals})}
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">高层认知</p>
              <h2>SOUL 与 USER 快照</h2>
            </div>
          </div>

          <div class="stack-layout stack-layout--tight">
            <article class="detail-card">
              <span class="section-kicker">SOUL</span>
              {code_block(%{content: @state.soul_preview})}
            </article>
            <article class="detail-card">
              <span class="section-kicker">USER</span>
              {code_block(%{content: @state.user_preview})}
            </article>
          </div>
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">长期事实</p>
              <h2>MEMORY 快照</h2>
            </div>
          </div>

          {code_block(%{content: @state.memory_preview})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">最近结果</p>
            <h2>最近几次进化相关记录</h2>
          </div>
        </div>

        {audit_glance(%{rows: Enum.take(@state.recent_events, 6)})}
      </section>

      <section class="section-card" id="manual-cycle">
        <div class="section-head">
          <div>
            <p class="section-kicker">手动运行</p>
            <h2>只有看完分层证据后，才建议手动触发 cycle</h2>
          </div>
        </div>

        <p class="section-summary">
          这不是默认动作。先看 `signals`、最近结果和高层认知，再决定是否需要人工触发一次分层整理。
        </p>

        <div class="actions-row">
          <form hx-post="/trigger_cycle" hx-target="#evolution-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">手动运行 cycle</button>
          </form>
          <div id="evolution-action-result" class="action-result"></div>
        </div>
      </section>

      <section class="section-card" id="evolution-audit">
        <div class="section-head">
          <div>
            <p class="section-kicker">审计流</p>
            <h2>完整进化时间线</h2>
          </div>
        </div>

        {audit_table(%{rows: @state.recent_events})}
      </section>
    </div>
    """
  end

  def skills_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">SKILL / TOOL</p>
            <h2>这里承接方法沉淀与确定性能力，不和认知层或代码层混在一起</h2>
          </div>
        </div>

        <p class="section-summary">
          `SKILL` 是可复用流程，`TOOL` 是可调用能力。它们都属于能力层，但不应该被当成同一种东西展示。
        </p>

        <div class="metric-grid">
          {metric(%{label: "本地 skills", value: length(@state.local_skills), tone: "gold"})}
          {metric(%{label: "runtime packages", value: length(@state.runtime_packages), tone: "ink"})}
          {metric(%{label: "builtin tools", value: length(@state.tools.builtin), tone: "green"})}
          {metric(%{label: "custom tools", value: length(@state.tools.custom), tone: "rust"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">SKILL</p>
              <h2>本地方法与流程</h2>
            </div>
          </div>

          {local_skills(%{skills: @state.local_skills})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">TOOL</p>
              <h2>当前可调用能力</h2>
            </div>
          </div>

          {tool_inventory_list(%{tools: @state.tools})}
        </section>
      </div>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">runtime packages</p>
              <h2>已进入运行时的能力包</h2>
            </div>
          </div>

          {runtime_packages(%{packages: @state.runtime_packages})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">近期 runs</p>
              <h2>能力运行轨迹</h2>
            </div>
          </div>

          {run_list(%{runs: @state.recent_runs})}
        </section>
      </div>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">lineage</p>
              <h2>能力进化谱系</h2>
            </div>
          </div>

          {lineage_list(%{events: @state.lineage})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">catalog</p>
              <h2>trusted catalog</h2>
            </div>
          </div>

          {catalog_list(%{entries: @state.runtime_catalog})}
        </section>
      </div>
    </div>
    """
  end

  def memory_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">SOUL / USER / MEMORY</p>
            <h2>认知层只负责长期原则、用户画像与环境事实，不负责方法和实现</h2>
          </div>
          <a class="ghost-link" href="/sessions">去会话页</a>
        </div>

        <p class="section-summary">
          这一页把高层认知放在一起：`SOUL` 是长期原则，`USER` 是当前用户画像，`MEMORY` 是环境事实，`HISTORY` 是操作历史。需要会话证据时再跳去 `/sessions`。
        </p>

        <div class="metric-grid">
          {metric(%{label: "SOUL", value: if(String.trim(@state.soul_preview || "") == "", do: "empty", else: "loaded"), tone: "gold"})}
          {metric(%{label: "USER", value: if(String.trim(@state.user_preview || "") == "", do: "empty", else: "loaded"), tone: "green"})}
          {metric(%{label: "MEMORY bytes", value: @state.memory_bytes, tone: "ink"})}
          {metric(%{label: "HISTORY bytes", value: @state.history_bytes, tone: "rust"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">SOUL</p>
              <h2>身份与长期原则</h2>
            </div>
          </div>

          {code_block(%{content: @state.soul_preview})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">USER</p>
              <h2>用户画像与协作偏好</h2>
            </div>
          </div>

          {code_block(%{content: @state.user_preview})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">MEMORY.md</p>
            <h2>长期事实与项目上下文</h2>
          </div>
        </div>

        {code_block(%{content: @state.memory_preview})}
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">HISTORY.md</p>
              <h2>历史记录</h2>
            </div>
          </div>

          {code_block(%{content: @state.history_preview})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">最近变化</p>
              <h2>与认知层相关的最近记录</h2>
            </div>
          </div>

          {audit_glance(%{rows: Enum.take(@state.recent_events, 8)})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">下一步</p>
            <h2>需要运行证据或分层判断时</h2>
          </div>
        </div>

        {workflow_links(%{
          links: [
            %{href: "/sessions", title: "回到会话页", body: "从单条 session 检查消息、未 consolidation 数量，再决定是否整理记忆。"},
            %{href: "/evolution", title: "回到分层总览", body: "如果你在判断这条变化该落在哪一层，直接回 `/evolution` 看六层地图。"}
          ]
        })}
      </section>
    </div>
    """
  end

  def sessions_panel(assigns) do
    ~H"""
    <div class="split-layout split-layout--sessions">
      <section class="section-card split-sidebar">
        <div class="section-head">
          <div>
            <p class="section-kicker">会话目录</p>
            <h2>按 session 进入检查</h2>
          </div>
        </div>

        {session_list(%{sessions: @state.sessions, compact: false})}
      </section>

      <div class="split-main">
        <%= if @state.selected_session do %>
          <section class="section-card section-card--hero">
            <div class="section-head">
              <div>
                <p class="section-kicker">当前会话</p>
                <h2>{@state.selected_session.key}</h2>
              </div>
            </div>

            <p class="section-summary">
              先确认消息规模与未 consolidation 数量，再决定是整理记忆还是直接清空这个 session。
            </p>

            <div id="sessions-action-result" class="action-result"></div>

            <div class="detail-grid">
              {detail_item(%{label: "消息数", value: @state.selected_session.total_messages})}
              {detail_item(%{label: "未 consolidation", value: @state.selected_session.unconsolidated_messages})}
              {detail_item(%{label: "最后更新", value: format_timestamp(@state.selected_session.updated_at)})}
            </div>

            <div class="actions-row">
              <form hx-post="/consolidate" hx-target="#sessions-action-result" hx-swap="innerHTML">
                <input type="hidden" name="session_key" value={@state.selected_session.key} />
                <button class="action-button action-button--primary" type="submit">运行 consolidation</button>
              </form>

              <form
                hx-post="/reset"
                hx-target="#sessions-action-result"
                hx-swap="innerHTML"
                hx-confirm="确认清空这个 session 吗？"
              >
                <input type="hidden" name="session_key" value={@state.selected_session.key} />
                <button class="action-button action-button--danger" type="submit">清空会话</button>
              </form>
            </div>
          </section>

          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">消息</p>
                <h2>当前会话内容</h2>
              </div>
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
          </section>
        <% else %>
          <section class="section-card">
            {empty_state(%{title: "没有找到 session", body: "先让 agent 跑起来，控制台才有可检查的会话。"})}
          </section>
        <% end %>
      </div>
    </div>
    """
  end

  def tasks_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">scheduled tasks</p>
            <h2>围绕 cron 和任务结果做调度管理</h2>
          </div>
        </div>

        <p class="section-summary">
          任务页只看调度和执行，不再重复展示运行时健康；先看下一批任务，再决定启停或手动触发。
        </p>

        <div class="metric-grid">
          {metric(%{label: "待处理任务", value: @state.summary.open, tone: "gold"})}
          {metric(%{label: "已完成任务", value: @state.summary.completed, tone: "green"})}
          {metric(%{label: "cron jobs", value: length(@state.cron_jobs), tone: "ink"})}
          {metric(%{label: "已启用 cron", value: @state.cron_status.enabled, tone: "rust"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">cron 状态</p>
              <h2>计划任务与启停</h2>
            </div>
          </div>

          <div id="tasks-action-result" class="action-result"></div>
          {cron_table(%{jobs: @state.cron_jobs})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">next runs</p>
              <h2>即将到来的任务</h2>
            </div>
          </div>

          {upcoming_list(%{rows: @state.summary.upcoming})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">执行结果</p>
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
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">运行时控制</p>
            <h2>先确认网关，再检查 services 和 heartbeat</h2>
          </div>
        </div>

        <p class="section-summary">
          运行时页只承担操作与健康检查，不再重复任务清单或记忆内容。
        </p>

        <div id="runtime-action-result" class="action-result"></div>

        <div class="detail-grid">
          {detail_item(%{label: "状态", value: @state.gateway.status})}
          {detail_item(%{label: "启动时间", value: format_timestamp(@state.gateway.started_at)})}
          {detail_item(%{label: "Provider", value: get_in(@state.gateway, [:config, :provider])})}
          {detail_item(%{label: "Model", value: get_in(@state.gateway, [:config, :model])})}
        </div>

        <div class="actions-row">
          <form hx-post="/start_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">启动网关</button>
          </form>

          <form hx-post="/stop_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--danger" type="submit">停止网关</button>
          </form>
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">services</p>
              <h2>运行时服务</h2>
            </div>
          </div>

          {services_grid(%{services: @state.gateway.services || %{}})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">heartbeat</p>
              <h2>维护节拍</h2>
            </div>
          </div>

          <div class="detail-grid">
            {detail_item(%{label: "Enabled", value: readable_bool(@state.heartbeat.enabled)})}
            {detail_item(%{label: "Running", value: readable_bool(@state.heartbeat.running)})}
            {detail_item(%{label: "Interval", value: @state.heartbeat.interval})}
          </div>
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">workspace</p>
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
    <div class="split-layout split-layout--code">
      <aside class="split-sidebar">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">CODE</p>
              <h2>最后一层的可热更模块</h2>
            </div>
          </div>

          <form method="get" action="/code" class="inline-form">
            <label for="module">当前模块</label>
            <select id="module" name="module">
              <%= for module <- @state.modules do %>
                <option value={module} selected={module == @state.selected_module}>{module}</option>
              <% end %>
            </select>
            <button class="action-button" type="submit">加载模块</button>
          </form>
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">版本轨迹</p>
              <h2>历史版本与回滚点</h2>
            </div>
          </div>

          {version_list(%{versions: @state.versions, selected_module: @state.selected_module})}
        </section>
      </aside>

      <div class="split-main">
        <section class="section-card section-card--editor">
          <div class="section-head">
            <div>
              <p class="section-kicker">代码层工作台</p>
              <h2>只有高层不能解决时，才进入这里做 diff、热更和回滚</h2>
            </div>
          </div>

          <p class="section-summary">
            左侧只负责选择模块与查看版本轨迹。这里是最后一层：对内部实现做直接修改，影响范围最大，也必须最谨慎。
          </p>

          <div id="code-action-result" class="action-result"></div>

          <div class="detail-grid">
            {detail_item(%{label: "当前模块", value: @state.selected_module})}
            {detail_item(%{label: "版本数", value: length(@state.versions)})}
            {detail_item(%{label: "最近代码事件", value: length(@state.recent_events)})}
          </div>

          <form class="editor-form">
            <input type="hidden" name="module" value={@state.selected_module} />

            <label for="reason">变更原因</label>
            <input id="reason" type="text" name="reason" value="Console hot upgrade" />

            <label for="code">新源码</label>
            <textarea id="code" name="code">{@state.current_source}</textarea>

            <div class="actions-row">
              <button
                type="submit"
                class="action-button"
                hx-post="/preview"
                hx-target="#code-action-result"
                hx-swap="innerHTML"
              >
                预览 diff
              </button>

              <button
                type="submit"
                class="action-button action-button--primary"
                hx-post="/hot_upgrade"
                hx-target="#code-action-result"
                hx-swap="innerHTML"
              >
                应用热更
              </button>
            </div>
          </form>

          <form class="inline-form" hx-post="/rollback" hx-target="#code-action-result" hx-swap="innerHTML">
            <input type="hidden" name="module" value={@state.selected_module} />
            <label for="version_id">回滚目标</label>
            <select id="version_id" name="version_id">
              <option value="">最近一个历史版本</option>
              <%= for version <- @state.versions do %>
                <option value={version.id}>{version.id}</option>
              <% end %>
            </select>
            <button class="action-button action-button--danger" type="submit">回滚</button>
          </form>
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">变更历史</p>
              <h2>最近代码层事件</h2>
            </div>
          </div>

          {audit_table(%{rows: @state.recent_events})}
        </section>
      </div>
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
      <header class="section-head">
        <div>
          <p class="section-kicker">Preview</p>
          <h2>{@module}</h2>
        </div>
      </header>

      {code_block(%{content: @diff})}
    </section>
    """
  end

  defp layer_map(assigns) do
    ~H"""
    <div class="layer-grid">
      <%= for layer <- @layers do %>
        <a class="layer-card" href={layer.href}>
          <header class="layer-card__head">
            <strong>{layer.key}</strong>
            <span>进入</span>
          </header>
          <p class="layer-card__summary">{layer.summary}</p>
          <small>{layer.detail}</small>
        </a>
      <% end %>
    </div>
    """
  end

  defp rule_list(assigns) do
    ~H"""
    <div class="rule-list">
      <%= for rule <- @rules do %>
        <article class="rule-list__item">
          <strong>{rule}</strong>
        </article>
      <% end %>
    </div>
    """
  end

  defp tool_inventory_list(assigns) do
    ~H"""
    <div class="tool-clusters">
      <section class="tool-cluster">
        <header class="tool-cluster__head">
          <strong>builtin tools</strong>
          <span>{length(@tools.builtin)}</span>
        </header>
        {tool_entries(%{entries: @tools.builtin, empty_title: "没有 builtin tools", empty_body: "Registry 里没有检测到可展示的内置工具。"})}
      </section>

      <section class="tool-cluster">
        <header class="tool-cluster__head">
          <strong>custom tools</strong>
          <span>{length(@tools.custom)}</span>
        </header>
        {tool_entries(%{entries: @tools.custom, empty_title: "没有 custom tools", empty_body: "tools/ 下还没有自定义能力。"})}
      </section>
    </div>
    """
  end

  defp tool_entries(assigns) do
    ~H"""
    <%= if @entries == [] do %>
      {empty_state(%{title: @empty_title, body: @empty_body})}
    <% else %>
      <div class="stack-list">
        <%= for entry <- @entries do %>
          <article class="stack-list__item">
            <header>
              <strong>{entry["name"]}</strong>
              <span>{Enum.map_join(entry["layers"] || ["tool"], " / ", &String.upcase/1)}</span>
            </header>
            <p>{entry["description"] || entry["module"] || entry["origin"] || "No description"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp workflow_links(assigns) do
    ~H"""
    <div class="workflow-grid">
      <%= for link <- @links do %>
        <a class="workflow-link" href={link.href}>
          <strong class="workflow-link__title">{link.title}</strong>
          <p>{link.body}</p>
        </a>
      <% end %>
    </div>
    """
  end

  defp audit_glance(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "暂无相关记录", body: "相关动作发生后，这里会出现最近几条摘要。"})}
    <% else %>
      <div class="stack-list">
        <%= for row <- @rows do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(row, "event")}</strong>
              <span>{format_timestamp(Map.get(row, "timestamp"))}</span>
            </header>
            <p>{payload_summary(Map.get(row, "payload", %{}))}</p>
          </article>
        <% end %>
      </div>
    <% end %>
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
          <span class="service-chip__label">{name}</span>

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
    <%= if @events == [] do %>
      {empty_state(%{title: "暂无实时事件", body: "Gateway、任务或进化动作发生后，这里会持续更新。"})}
    <% else %>
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
    <% end %>
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
            <pre class="audit-table__payload"><code>{payload_preview(Map.get(row, "payload", %{}))}</code></pre>
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
          <span class="service-chip__label">{row.name}</span>

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
      <strong>{@value || "n/a"}</strong>
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

  defp page_name(path), do: path |> page_meta() |> Map.get(:name)
  defp page_group(path), do: path |> page_meta() |> Map.get(:group)

  defp page_meta(path) do
    Map.get(@page_meta, path, %{name: "控制台", group: "运行证据"})
  end

  defp payload_preview(payload) do
    inspect(payload, pretty: true, printable_limit: 4_000, limit: 80)
  end

  defp payload_summary(payload) when payload in [%{}, nil], do: "没有额外 payload"

  defp payload_summary(payload) do
    payload
    |> payload_preview()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
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

  defp format_timestamp(%DateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp format_timestamp(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

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
