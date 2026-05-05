defmodule NexAgentConsole.Pages.Index do
  use Nex

  def mount(_params), do: {:redirect, "/traces"}
end
