defmodule NexAgentConsole.Support.View do
  @moduledoc false

  def render(content) when is_binary(content), do: content
  def render(content), do: Phoenix.HTML.Safe.to_iodata(content) |> IO.iodata_to_binary()
end
