defmodule NexAgentConsole.Pages.Traces.RunId do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.TraceUI
  alias NexAgentConsole.Support.TraceView

  def mount(%{"run_id" => run_id} = params) do
    opts = params |> workspace_opts() |> Keyword.put(:trace, run_id)
    state = Admin.runtime_state(opts)

    case state.selected_request_trace do
      nil ->
        :not_found

      trace ->
        %{
          title: "Trace #{run_id}",
          workspace: state.workspace,
          trace: trace,
          events: trace.events || [],
          started_at: started_at(trace),
          completed_at: completed_at(trace)
        }
    end
  end

  def render(assigns) do
    ~H"""
    <main class="page page--detail">
      <a class="back-link" href={back_href(@workspace)}>← Back to traces</a>

      {TraceUI.trace_header(%{
        trace: @trace,
        started_at: @started_at,
        completed_at: @completed_at
      })}

      <section class="summary-strip">
        <span class="pill">{@trace.llm_rounds || 0} LLM rounds</span>
        <span class="pill">{@trace.tool_count || 0} tools</span>
        <span class="pill">{length(@events)} events</span>
        <span class="pill">{length(@trace.selected_packages || [])} selected skills</span>
      </section>

      {TraceUI.timeline(%{events: @events})}

      <section class="panel">
        <details class="raw-details raw-details--full">
          <summary>Raw JSONL events</summary>
          <pre><code>{TraceView.json_dump(@events)}</code></pre>
        </details>
      </section>
    </main>
    """
  end

  defp workspace_opts(%{"workspace" => workspace}) when is_binary(workspace) and workspace != "",
    do: [workspace: workspace]

  defp workspace_opts(_params), do: []

  defp started_at(trace), do: trace.inserted_at

  defp completed_at(trace) do
    trace.events
    |> Enum.find(&(&1["type"] == "request_completed"))
    |> case do
      nil -> nil
      event -> event["inserted_at"]
    end
  end

  defp back_href(workspace) when is_binary(workspace) and workspace != "",
    do: "/traces?workspace=" <> URI.encode(workspace)

  defp back_href(_), do: "/traces"
end
