defmodule Nex.Agent.Tool.Behaviour do
  @moduledoc """
  Tool behavior callback for all agent tools.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback category() :: :base | :evolution | :skill
  @callback definition() :: map()
  @callback execute(map(), map()) :: {:ok, any()} | {:error, String.t()}

  @optional_callbacks [name: 0, description: 0, category: 0]
end
