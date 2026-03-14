defmodule Nex.Agent.Security do
  @moduledoc """
  Security utilities for the agent.

  Provides path validation, command blacklist validation, and other security checks.
  """

  @blocked_commands [
    "mkfs",
    "fdisk",
    "parted",
    "diskpart",
    "dd",
    "shutdown",
    "reboot",
    "poweroff",
    "halt",
    "nc",
    "netcat",
    "ncat",
    "sudo",
    "su"
  ]

  @blocked_shells ~w(bash sh zsh fish csh tcsh dash ksh)

  @dangerous_patterns [
    {~r/\brm\s+(-[^\s]*\s+)*\/(bin|sbin|usr|etc|var|boot|lib|sys|proc)\b/i,
     "Deleting system directories not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*\/\s*$/i, "Deleting from root not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*~\/?\s*$/i, "Deleting entire home directory not allowed"},
    {~r/\bdel\s+\/[fq]\b/i, "Forced file deletion not allowed"},
    {~r/\brmdir\s+\/s\b/i, "Recursive directory deletion not allowed"},
    {~r/(?:^|[;&|]\s*)format\b/i, "Disk formatting not allowed"},
    {~r/\b(mkfs|diskpart)\b/i, "Disk operations not allowed"},
    {~r/\bdd\s+if=/i, "Raw disk copy not allowed"},
    {~r/>\s*\/dev\/sd/i, "Writing to block devices not allowed"},
    {~r/\b(shutdown|reboot|poweroff)\b/i, "System power control not allowed"},
    {~r/:\(\)\s*\{.*\};\s*:/, "Fork bomb not allowed"},
    {~r/[;&|]\s*(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\s+-[ic]/i, "Shell injection not allowed"},
    {~r/`[^`]+`/, "Command substitution not allowed"},
    {~r/\$\([^)]+\)/, "Command substitution not allowed"},
    {~r/\b(env|xargs|exec|nice|timeout)\s+.*\b(bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i,
     "Shell command escape not allowed"},
    {~r/\bpython\b.*-c\b/i, "Python command execution not allowed"},
    {~r/\bperl\b.*-e\b/i, "Perl command execution not allowed"},
    {~r/\bruby\b.*-e\b/i, "Ruby command execution not allowed"},
    {~r/\bnode\b.*-e\b/i, "Node.js command execution not allowed"},
    {~r/\bphp\b.*-r\b/i, "PHP command execution not allowed"},
    {~r/\b(os\.system|subprocess|eval\(|exec\(|import\s+os)\b/i,
     "Python system calls not allowed"}
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

    path_within_allowed_roots?(expanded, roots) and
      not symlink_escapes_to_forbidden_path?(expanded, roots)
  end

  defp path_within_allowed_roots?(expanded_path, roots) do
    Enum.any?(roots, fn root -> String.starts_with?(expanded_path, root) end)
  end

  defp symlink_escapes_to_forbidden_path?(path, roots) do
    case File.read_link(path) do
      {:ok, target} ->
        expanded_target = Path.expand(target)
        not path_within_allowed_roots?(expanded_target, roots)

      {:error, _} ->
        false
    end
  rescue
    _ -> false
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
    sanitized_command = remove_inline_comments(sanitized_command)

    first_token = normalized_command |> String.split(~r/\s+/, parts: 2) |> hd()
    base_cmd = extract_base_command(first_token)

    cond do
      base_cmd in @blocked_commands ->
        {:error, "Command blocked: #{base_cmd}"}

      base_cmd in @blocked_shells ->
        {:error, "Shell invocation blocked: #{base_cmd}"}

      true ->
        check_dangerous_patterns(sanitized_command)
    end
  end

  defp extract_base_command(token) do
    token
    |> String.split("/")
    |> List.last()
    |> String.split("@")
    |> List.first()
  end

  defp remove_inline_comments(command) do
    command
    |> String.replace(~r/\s+#.*$/, "")
  end

  defp check_dangerous_patterns(command) do
    case Enum.find_value(@dangerous_patterns, fn {pattern, reason} ->
           if Regex.match?(pattern, command), do: reason
         end) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @doc """
  Get the list of blocked commands.
  """
  @spec blocked_commands() :: [String.t()]
  def blocked_commands do
    @blocked_commands ++ @blocked_shells
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
