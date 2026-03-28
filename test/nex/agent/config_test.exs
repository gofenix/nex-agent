defmodule Nex.Agent.ConfigTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Config

  test "config validity accepts API key from environment for current provider" do
    previous = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "sk-env-test")

    on_exit(fn ->
      if previous do
        System.put_env("OPENAI_API_KEY", previous)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    config = %Config{Config.default() | provider: "openai"}

    assert Config.get_current_api_key(config) == "sk-env-test"
    assert Config.valid?(config)
  end

  test "skill_runtime config persists through save and load" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-config-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf!(path) end)

    config =
      %Config{
        Config.default()
        | skill_runtime: %{
            "enabled" => true,
            "max_selected_skills" => 3,
            "github_indexes" => [
              %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
            ]
          }
      }

    assert :ok = Config.save(config, config_path: path)

    loaded = Config.load(config_path: path)

    assert loaded.skill_runtime["enabled"] == true
    assert loaded.skill_runtime["max_selected_skills"] == 3
    assert [%{"repo" => "org/index"} | _] = loaded.skill_runtime["github_indexes"]
  end
end
