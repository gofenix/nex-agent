defmodule NexAgentConsole.Pages.Traces.Index do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.TraceUI

  def mount(params) do
    opts = workspace_opts(params)
    state = Admin.runtime_state(opts)

    %{
      title: "NexAgent Trace",
      workspace: state.workspace,
      traces: state.recent_request_traces,
      trace_enabled: state.request_trace_config["enabled"] == true,
      trace_dir: state.request_trace_config["dir"]
    }
  end

  def render(assigns) do
    ~H"""
    <main class="page page--list">
      <section class="page-heading">
        <div>
          <span class="section-kicker">request traces</span>
          <h1>Trace conversations</h1>
          <p class="muted">Exact-time execution records from the NexAgent runtime.</p>
        </div>
        <span class="pill mono">trace <%= if @trace_enabled, do: "enabled", else: "disabled" %></span>
      </section>

      <%= unless @trace_enabled do %>
        {TraceUI.disabled_trace_notice(%{dir: @trace_dir})}
      <% end %>

      <%= if @traces == [] do %>
        {TraceUI.empty_state(%{
          title: "No request traces found",
          body: "Trace files will appear here after request tracing is enabled and the agent handles a run."
        })}
      <% else %>
        <section class="trace-list">
          <%= for trace <- @traces do %>
            {TraceUI.trace_row(%{trace: trace, workspace: @workspace})}
          <% end %>
        </section>
      <% end %>
    </main>
    """
  end

  defp workspace_opts(%{"workspace" => workspace}) when is_binary(workspace) and workspace != "",
    do: [workspace: workspace]

  defp workspace_opts(_params), do: []
end
