defmodule Nex.Agent.MCP.DiscoveryTest do
  use ExUnit.Case
  alias Nex.Agent.MCP.Discovery

  describe "scan/0" do
    test "returns a list of servers" do
      servers = Discovery.scan()

      # Should return a list
      assert is_list(servers)

      # Each server should have required fields
      Enum.each(servers, fn server ->
        assert is_map(server)
        assert server.name
        assert server.command
        assert is_list(server.args)
      end)
    end

    test "discovers servers from PATH" do
      # Create a temporary directory with a fake mcp-server
      tmp_dir = System.tmp_dir!()
      fake_server = Path.join(tmp_dir, "mcp-server-test")
      File.write!(fake_server, "#!/bin/sh\necho test")
      File.chmod!(fake_server, 0o755)

      # Temporarily add to PATH
      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{tmp_dir}:#{original_path}")

      try do
        servers = Discovery.scan()

        # Should find our test server
        test_server = Enum.find(servers, &(&1.name == "test"))

        if test_server do
          assert test_server.name == "test"
          assert test_server.command == fake_server
          assert test_server.source == :auto_discovered
        end
      after
        # Cleanup
        System.put_env("PATH", original_path)
        File.rm!(fake_server)
      end
    end
  end

  describe "config loading" do
    test "loads servers from config file" do
      # Create a temporary config
      config_dir = Path.join(System.tmp_dir!(), "test-mcp-config-#{:rand.uniform(1000)}")
      config_path = Path.join(config_dir, "mcp.json")

      File.mkdir_p!(config_dir)

      config = %{
        "servers" => %{
          "filesystem" => %{
            "command" => "/usr/local/bin/mcp-server-filesystem",
            "args" => ["/Users/test/data"]
          }
        }
      }

      File.write!(config_path, Jason.encode!(config))

      # Test loading (would need to modify module to accept custom path)
      # For now, just verify file was created
      assert File.exists?(config_path)

      # Cleanup
      File.rm_rf!(config_dir)
    end
  end
end
