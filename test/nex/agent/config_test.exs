defmodule Nex.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Config

  test "default includes telegram settings" do
    config = Config.default()
    telegram = Config.telegram(config)

    assert telegram["enabled"] == false
    assert telegram["token"] == ""
    assert telegram["allow_from"] == []
    assert telegram["reply_to_message"] == false
    assert Map.has_key?(telegram, "proxy")
  end

  test "telegram enabled requires token" do
    config =
      Config.default()
      |> Config.set(:provider, "ollama")
      |> Config.set(:telegram_enabled, true)

    refute Config.valid?(config)

    config = Config.set(config, :telegram_token, "123:abc")
    assert Config.valid?(config)
  end

  test "telegram allow_from normalization" do
    config =
      Config.default()
      |> Config.set(:telegram_allow_from, [" 42", "alice", "42", "", "alice "])

    assert Config.telegram_allow_from(config) == ["42", "alice"]
  end
end
