defmodule Nex.Agent.LLM.Behaviour do
  @moduledoc """
  LLM provider behaviour
  """

  @callback chat(messages :: [map()], options :: map()) :: {:ok, map()} | {:error, term()}
  @callback stream(messages :: [map()], options :: map(), fun()) :: :ok | {:error, term()}
  @callback tools() :: [map()]
end
