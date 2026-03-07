defmodule Nex.Agent.Security do
  @moduledoc """
  Security utilities for the agent.

  Provides path validation, command whitelisting, and other security checks.
  """

  @allowed_roots_default [
    # Project directory
    File.cwd!(),
    # Agent workspace
    Path.expand("~/.nex/agent"),
    # Temp directory (for tests and operations)
    "/tmp"
  ]

  # Base commands allowed in production
  @allowed_commands_prod [
    # Version control
    "git",
    "hg",
    # Build tools
    "mix",
    "elixir",
    "erlc",
    "rebar3",
    "make",
    "cmake",
    # File operations
    "ls",
    "dir",
    "cat",
    "head",
    "tail",
    "grep",
    "find",
    "wc",
    "sort",
    "uniq",
    "mkdir",
    "rmdir",
    "cp",
    "mv",
    "rm",
    "touch",
    "ln",
    "stat",
    "file",
    "chmod",
    "chown",
    "pwd",
    "basename",
    "dirname",
    "realpath",
    # Text processing
    "awk",
    "sed",
    "sort",
    "cut",
    "tr",
    "tee",
    "diff",
    "patch",
    "xargs",
    # Process
    "ps",
    "kill",
    "killall",
    "top",
    "htop",
    # Network (read-only)
    "curl",
    "wget",
    "ssh",
    "scp",
    "rsync",
    "ping",
    "dig",
    "nslookup",
    "host",
    # Development
    "npm",
    "npx",
    "node",
    "yarn",
    "pnpm",
    "bun",
    "deno",
    "python",
    "python3",
    "pip",
    "pip3",
    "cargo",
    "rustc",
    "go",
    "ruby",
    "gem",
    "java",
    "javac",
    "gradle",
    "mvn",
    # Docker (read-only)
    "docker",
    "podman",
    # Package managers
    "brew",
    "apt",
    "apt-get",
    "yum",
    "dnf",
    "pacman",
    # Misc
    "date",
    "echo",
    "printf",
    "true",
    "false",
    "which",
    "whoami",
    "id",
    "env",
    "printenv",
    "uname",
    "hostname",
    "tar",
    "zip",
    "unzip",
    "gzip",
    "gunzip",
    "jq",
    "yq",
    "bc",
    "md5sum",
    "sha256sum",
    "base64"
  ]

  # Commands allowed in test environment (includes extra testing utilities)
  @allowed_commands_test @allowed_commands_prod ++ ["seq", "exit", "test", "sleep"]

  @doc """
  Get the list of allowed root directories for file access.
  """
  @spec allowed_roots() :: [String.t()]
  def allowed_roots do
    # Can be configured via environment variable
    case System.get_env("NEX_ALLOWED_ROOTS") do
      nil -> @allowed_roots_default
      paths -> String.split(paths, ":") |> Enum.map(&Path.expand/1)
    end
  end

  @doc """
  Validate that a path is within allowed roots.

  Returns {:ok, expanded_path} if valid, {:error, reason} if not.
  """
  @spec validate_path(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(path) do
    expanded = Path.expand(path)

    # Check for path traversal attempts
    if String.contains?(path, "..") and not safe_traversal?(path) do
      {:error, "Path traversal not allowed: #{path}"}
    else
      # Check if within allowed roots
      roots = allowed_roots()

      if Enum.any?(roots, fn root -> String.starts_with?(expanded, root) end) do
        {:ok, expanded}
      else
        {:error, "Path not within allowed roots. Allowed: #{Enum.join(roots, ", ")}"}
      end
    end
  end

  # Check if traversal is safe (doesn't escape allowed roots)
  defp safe_traversal?(path) do
    expanded = Path.expand(path)
    roots = allowed_roots()

    Enum.any?(roots, fn root ->
      String.starts_with?(expanded, root) && String.starts_with?(Path.expand(path), root)
    end)
  end

  @doc """
  Get the list of allowed commands.
  """
  @spec allowed_commands() :: [String.t()]
  def allowed_commands do
    if Application.get_env(:nex_agent, :env) == :test do
      @allowed_commands_test
    else
      @allowed_commands_prod
    end
  end

  @doc """
  Validate a command against the whitelist.

  Returns :ok if allowed, {:error, reason} if not.
  """
  @spec validate_command(String.t()) :: :ok | {:error, String.t()}
  def validate_command("") do
    # Empty command is allowed (will fail at execution)
    :ok
  end

  def validate_command(command) do
    # Extract the base command
    base_cmd = command |> String.trim() |> String.split() |> hd()

    # Check for dangerous patterns
    dangerous_patterns = [
      # Destructive file operations
      {~r/rm\s+(-[^\s]*\s+)*\/(bin|sbin|usr|etc|var|boot|lib|sys|proc)\b/, "Deleting system directories not allowed"},
      {~r/rm\s+(-[^\s]*\s+)*\/\s/, "Deleting from root not allowed"},
      {~r/rm\s+(-[^\s]*\s+)*~\/\s*$/, "Deleting entire home directory not allowed"},
      # Disk/device operations
      {~r/\bdd\s+.*if=\/dev\//, "Raw device read with dd not allowed"},
      {~r/\bmkfs\b/, "Filesystem creation not allowed"},
      {~r/\bfdisk\b/, "Disk partitioning not allowed"},
      {~r/\bparted\b/, "Disk partitioning not allowed"},
      # System control
      {~r/\bshutdown\b/, "System shutdown not allowed"},
      {~r/\breboot\b/, "System reboot not allowed"},
      {~r/\bpoweroff\b/, "System poweroff not allowed"},
      {~r/\binit\s+[06]\b/, "System init change not allowed"},
      {~r/\bsystemctl\s+(halt|poweroff|reboot|shutdown)/, "System control not allowed"},
      # Fork bombs and resource exhaustion
      {~r/:\(\)\s*\{\s*:\|:&\s*\}\s*;:/, "Fork bomb not allowed"},
      {~r/\bwhile\s+true.*do.*done/, "Infinite loop not allowed"},
      {~r/\byes\s*\|/, "Infinite output pipe not allowed"},
      # Dangerous permissions
      {~r/chmod\s+(-[^\s]*\s+)*[0-7]*7[0-7]*\s+\//, "Dangerous permission change on system dirs not allowed"},
      {~r/chown\s+.*\s+\//, "Changing ownership of system dirs not allowed"},
      # Remote code execution
      {~r/^\.\.\//, "Relative path traversal not allowed"},
      {~r/;\s*sh\s*-i/, "Interactive shell spawn not allowed"},
      {~r/\|.*sh$/, "Shell pipe to interactive shell not allowed"},
      {~r/curl.*\|\s*(ba)?sh/, "curl | sh pattern not allowed"},
      {~r/wget.*\|\s*(ba)?sh/, "wget | sh pattern not allowed"},
      {~r/\beval\s+"?\$\(curl/, "Remote code eval not allowed"},
      # Device writes
      {~r/>\s*\/dev\//, "Writing to /dev not allowed"},
      # Credential/key exfiltration
      {~r/cat\s+.*\.(pem|key|p12|pfx|jks)\b/, "Reading key files not allowed"},
      {~r/cat\s+.*\/\.ssh\//, "Reading SSH keys not allowed"},
      {~r/cat\s+.*\/\.env\b/, "Reading .env files not allowed"},
      # Network exfiltration
      {~r/curl\s+.*-d\s+@/, "Sending file contents via curl not allowed"},
      {~r/nc\s+-[^\s]*l/, "Netcat listener not allowed"},
      # Other
      {~r/2>&1.*rm/, "Redirect stderr to rm not allowed"},
      {~r/\b(crontab|at)\s+-/, "Modifying scheduled tasks not allowed"}
    ]

    # Check dangerous patterns first
    case Enum.find_value(dangerous_patterns, fn {pattern, reason} ->
           if Regex.match?(pattern, command), do: reason
         end) do
      nil ->
        # No dangerous pattern found, check whitelist
        allowed = allowed_commands()

        if base_cmd in allowed do
          :ok
        else
          {:error, "Command not allowed: #{base_cmd}. Allowed: #{Enum.join(allowed, ", ")}"}
        end

      reason ->
        {:error, reason}
    end
  end
end
