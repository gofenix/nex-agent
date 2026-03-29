defmodule NexAgentConsole.Api.Admin.Events do
  use Nex

  alias Nex.Agent.Admin

  def get(_req) do
    Nex.stream(fn send ->
      Admin.subscribe_events(self())

      Admin.recent_events(limit: 12)
      |> Enum.reverse()
      |> Enum.each(fn event ->
        send.(%{event: "admin-event", data: event})
      end)

      loop(send)
    end)
  end

  defp loop(send) do
    receive do
      {:bus_message, _, event} ->
        send.(%{event: "admin-event", data: event})
        loop(send)
    after
      15_000 ->
        send.({:raw, ": keep-alive\n\n"})
        loop(send)
    end
  end
end
