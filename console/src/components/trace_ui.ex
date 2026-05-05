defmodule NexAgentConsole.Components.TraceUI do
  use Nex

  alias NexAgentConsole.Support.TraceView

  def trace_row(assigns) do
    assigns = Map.put(assigns, :trace, assigns.trace)

    ~H"""
    <a class="trace-row" href={"/traces/#{@trace.run_id}#{workspace_query(assigns)}"}>
      <div class="trace-row__top">
        <span class="status-line">
          <span class={["status-dot", TraceView.status_class(@trace.status)]}></span>
          <span class="mono">{TraceView.status_label(@trace.status)}</span>
        </span>
        <time class="exact-time">{TraceView.format_timestamp(@trace.inserted_at)}</time>
      </div>

      <h2>{@trace.prompt || "(no prompt)"}</h2>

      <div class="trace-row__meta">
        <span :if={Map.get(@trace, :channel)} class="pill">{@trace.channel}</span>
        <span :if={Map.get(@trace, :chat_id)} class="pill">{@trace.chat_id}</span>
        <span class="pill">{@trace.llm_rounds || 0} LLM</span>
        <span class="pill">{@trace.tool_count || 0} tools</span>
        <span class="pill">{length(@trace.selected_packages || [])} skills</span>
        <span class="pill mono">{@trace.run_id}</span>
      </div>

      <p :if={(Map.get(@trace, :used_tools) || []) != []} class="tool-line mono">
        {Enum.join(@trace.used_tools, " · ")}
      </p>
    </a>
    """
  end

  def trace_header(assigns) do
    ~H"""
    <header class="trace-detail-header">
      <div class="trace-detail-header__main">
        <h1>{@trace.prompt || "(no prompt)"}</h1>
        <p class="muted">
          {@trace.channel || "unknown channel"} · {@trace.chat_id || "unknown chat"} ·
          <span class="mono">{@trace.run_id}</span>
        </p>
        <p class="exact-time">
          Started {TraceView.format_timestamp(@started_at)} · Completed {TraceView.format_timestamp(@completed_at)}
        </p>
      </div>
      <div class="status-line trace-detail-header__status">
        <span class={["status-dot", TraceView.status_class(@trace.status)]}></span>
        <span class="mono">{TraceView.status_label(@trace.status)}</span>
      </div>
    </header>
    """
  end

  def timeline(assigns) do
    ~H"""
    <section class="panel">
      <div class="section-head">
        <span class="section-kicker">execution</span>
        <h2>Timeline</h2>
      </div>

      <div class="timeline">
        <%= for event <- @events do %>
          {event_item(%{event: event})}
        <% end %>
      </div>
    </section>
    """
  end

  def event_item(assigns) do
    assigns =
      assigns
      |> Map.put(:messages, TraceView.event_messages(assigns.event))
      |> Map.put(:available_tools, TraceView.event_tools(assigns.event))
      |> Map.put(:tool_calls, TraceView.event_tool_calls(assigns.event))

    ~H"""
    <article class={["event", TraceView.event_class(@event)]}>
      <div class="event__top">
        <time class="exact-time">{TraceView.format_timestamp(@event["inserted_at"])}</time>
        <strong class="mono">{TraceView.event_title(@event)}</strong>
      </div>
      <p class="muted">{TraceView.event_summary(@event)}</p>
      <details :if={@messages != []} class="trace-details">
        <summary>messages ({length(@messages)})</summary>
        <div class="trace-detail-list">
          <article :for={message <- @messages} class="trace-detail-item">
            <div class="trace-detail-item__head">
              <strong class="mono">{TraceView.message_role(message)}</strong>
            </div>
            <p>{TraceView.message_preview(message)}</p>
          </article>
        </div>
      </details>
      <details :if={@available_tools != []} class="trace-details">
        <summary>available tools ({length(@available_tools)})</summary>
        <div class="trace-detail-list trace-detail-list--tools">
          <article :for={tool <- @available_tools} class="trace-detail-item">
            <div class="trace-detail-item__head">
              <strong class="mono">{TraceView.tool_name(tool)}</strong>
            </div>
            <p :if={TraceView.tool_description(tool) != ""}>{TraceView.tool_description(tool)}</p>
            <details class="raw-details raw-details--nested">
              <summary>input schema</summary>
              <pre><code>{TraceView.json_dump(TraceView.tool_parameters(tool))}</code></pre>
            </details>
          </article>
        </div>
      </details>
      <details :if={@tool_calls != []} class="trace-details">
        <summary>tool calls ({length(@tool_calls)})</summary>
        <div class="trace-detail-list trace-detail-list--calls">
          <article :for={tool_call <- @tool_calls} class="trace-detail-item">
            <div class="trace-detail-item__head">
              <strong class="mono">{TraceView.tool_call_name(tool_call)}</strong>
              <span :if={TraceView.tool_call_id(tool_call) != ""} class="trace-detail-meta mono">
                {TraceView.tool_call_id(tool_call)}
              </span>
            </div>
            <details class="raw-details raw-details--nested">
              <summary>arguments</summary>
              <pre><code>{TraceView.json_dump(TraceView.tool_call_arguments(tool_call))}</code></pre>
            </details>
          </article>
        </div>
      </details>
      <details class="raw-details">
        <summary>raw event</summary>
        <pre><code>{TraceView.json_dump(@event)}</code></pre>
      </details>
    </article>
    """
  end

  def empty_state(assigns) do
    ~H"""
    <section class="empty-state">
      <strong>{@title}</strong>
      <p>{@body}</p>
    </section>
    """
  end

  def disabled_trace_notice(assigns) do
    ~H"""
    <section class="notice">
      <strong>Request trace is disabled.</strong>
      <span>Existing trace files are still shown when present.</span>
      <code>{@dir}</code>
    </section>
    """
  end

  defp workspace_query(assigns) do
    case Map.get(assigns, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        "?workspace=" <> URI.encode(workspace)

      _ ->
        ""
    end
  end
end
