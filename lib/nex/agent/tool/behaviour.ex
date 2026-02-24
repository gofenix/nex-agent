defmodule Nex.Agent.Tool.Behaviour do
  @moduledoc """
  Tool behavior callback
  """

  @callback definition() :: map()
  @callback execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
end
