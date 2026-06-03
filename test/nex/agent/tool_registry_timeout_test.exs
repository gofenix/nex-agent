defmodule Nex.Agent.ToolRegistryTimeoutTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Tool.Registry

  test "execute timeout follows tool args with grace" do
    assert Registry.execute_timeout_ms(%{"timeout" => 600}, %{}) == 605_000
  end

  test "execute timeout can come from context" do
    assert Registry.execute_timeout_ms(%{}, %{timeout: 300}) == 305_000
  end

  test "execute timeout keeps default grace" do
    assert Registry.execute_timeout_ms(%{}, %{}) == 125_000
  end
end
