defmodule Nex.SkillRuntime.GitHubAuth do
  @moduledoc false

  @spec token() :: String.t() | nil
  def token do
    System.get_env("GH_TOKEN") ||
      System.get_env("GITHUB_TOKEN") ||
      gh_cli_token()
  end

  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    headers = [{"accept", "application/vnd.github+json"}]

    case token() do
      nil -> headers
      token -> [{"authorization", "Bearer #{token}"} | headers]
    end
  end

  defp gh_cli_token do
    if System.find_executable("gh") do
      case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
        {token, 0} ->
          token = String.trim(token)
          if token == "", do: nil, else: token

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end
end
