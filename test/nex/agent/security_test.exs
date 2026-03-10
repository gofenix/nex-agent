defmodule Nex.Agent.SecurityTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Security
  alias Nex.Agent.Tool.Bash

  describe "validate_command/1 nanobot parity deny patterns" do
    test "blocks destructive deletion of root" do
      assert {:error, reason} = Security.validate_command("rm -rf /")
      assert reason =~ "Deleting from root not allowed"
    end

    test "blocks dd if= disk copy pattern" do
      assert {:error, reason} = Security.validate_command("dd if=/dev/zero of=/tmp/disk.img")
      assert reason =~ "Raw disk copy not allowed"
    end

    test "blocks write to block device" do
      assert {:error, reason} = Security.validate_command("echo x > /dev/sda")
      assert reason =~ "Writing to block devices not allowed"
    end

    test "allows benign whitelisted command" do
      assert :ok = Security.validate_command("echo hello")
    end

    test "allows workspace cleanup command" do
      assert :ok = Security.validate_command("rm -rf _build")
    end

    test "does not block quoted dangerous text" do
      assert :ok = Security.validate_command("echo 'rm -rf /'")
    end
  end

  describe "bash tool security enforcement" do
    test "rejects blocked commands before execution" do
      assert {:error, reason} = Bash.execute(%{"command" => "rm -rf /"}, %{})
      assert reason =~ "Security: Deleting from root not allowed"
    end

    test "executes allowed commands" do
      assert {:ok, output} = Bash.execute(%{"command" => "echo hello"}, %{})
      assert output =~ "hello"
    end
  end
end
