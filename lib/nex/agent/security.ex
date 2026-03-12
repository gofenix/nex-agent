defmodule Nex.Agent.Security do
  @moduledoc """
  Security utilities for the agent.

  Provides path validation, command blacklist validation, and other security checks.
  """

  # Dangerous commands that are explicitly blocked
  @blocked_commands [
    # System destruction
    "mkfs",
    "fdisk",
    "parted",
    "diskpart",
    # Raw disk operations
    "dd",
    # System power
    "shutdown",
    "reboot",
    "poweroff",
    "halt",
    # Network attacks
    "nc",
    "netcat",
    "ncat",
    # Privilege escalation
    "sudo",
    "su",
    # Shell escapes (these spawn interactive shells)
    "bash",
    "sh",
    "zsh",
    "fish",
    "csh",
    "tcsh"
  ]

  # Core shell deny patterns for shell safety
  @dangerous_patterns [
    # Target-aware deletion guards: allow workspace cleanup, block catastrophic targets.
    {~r/\brm\s+(-[^\s]*\s+)*\/(bin|sbin|usr|etc|var|boot|lib|sys|proc)\b/,
     "Deleting system directories not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*\/\s*$/, "Deleting from root not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*~\/?\s*$/, "Deleting entire home directory not allowed"},
    # Destructive shell commands
    {~r/\bdel\s+\/[fq]\b/, "Forced file deletion not allowed"},
    {~r/\brmdir\s+\/s\b/, "Recursive directory deletion not allowed"},
    {~r/(?:^|[;&|]\s*)format\b/, "Disk formatting not allowed"},
    {~r/\b(mkfs|diskpart)\b/, "Disk operations not allowed"},
    {~r/\bdd\s+if=/, "Raw disk copy not allowed"},
    {~r/>\s*\/dev\/sd/, "Writing to block devices not allowed"},
    {~r/\b(shutdown|reboot|poweroff)\b/, "System power control not allowed"},
    {~r/:\(\)\s*\{.*\};\s*:/, "Fork bomb not allowed"},
    # Shell injection attempts
    {~r/[;&|]\s*(?:bash|sh|zsh)\s+-[ic]/, "Shell injection not allowed"},
    {~r/`.*`/, "Command substitution not allowed"},
    {~r/\$\(.*\)/, "Command substitution not allowed"}
  ]

  @doc """
  Get the list of allowed root directories for file access.
  """
  @spec allowed_roots() :: [String.t()]
  def allowed_roots do
    case System.get_env("NEX_ALLOWED_ROOTS") do
      nil -> default_allowed_roots()
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

    if String.contains?(path, "..") and not safe_traversal?(path) do
      {:error, "Path traversal not allowed: #{path}"}
    else
      roots = allowed_roots()

      if Enum.any?(roots, fn root -> String.starts_with?(expanded, root) end) do
        {:ok, expanded}
      else
        {:error, "Path not within allowed roots. Allowed: #{Enum.join(roots, ", ")}"}
      end
    end
  end

  defp safe_traversal?(path) do
    expanded = Path.expand(path)
    roots = allowed_roots()

    Enum.any?(roots, fn root ->
      String.starts_with?(expanded, root) && String.starts_with?(Path.expand(path), root)
    end)
  end

  @doc """
  Validate a command against the blacklist.

  Returns :ok if allowed, {:error, reason} if not.
  """
  @spec validate_command(String.t()) :: :ok | {:error, String.t()}
  def validate_command("") do
    :ok
  end

  def validate_command(command) do
    normalized_command = command |> String.trim() |> String.downcase()
    sanitized_command = strip_quoted_segments(normalized_command)

    # Extract the base command
    base_cmd = normalized_command |> String.split() |> hd()

    # Check blocked commands first
    if base_cmd in @blocked_commands do
      {:error, "Command blocked: #{base_cmd}"}
    else
      # Check dangerous patterns
      case Enum.find_value(@dangerous_patterns, fn {pattern, reason} ->
             if Regex.match?(pattern, sanitized_command), do: reason
           end) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end
  end

  @doc """
  Get the list of blocked commands.
  """
  @spec blocked_commands() :: [String.t()]
  def blocked_commands do
    @blocked_commands
  end

  defp strip_quoted_segments(command) do
    command
    |> String.replace(~r/'[^']*'/, "''")
    |> String.replace(~r/"[^"]*"/, "\"\"")
  end

  defp default_allowed_roots do
    [
      File.cwd!(),
      Path.join(System.get_env("HOME", "~"), ".nex/agent"),
      Path.join(System.get_env("HOME", "~"), "github"),
      "/tmp"
    ]
  end
end
