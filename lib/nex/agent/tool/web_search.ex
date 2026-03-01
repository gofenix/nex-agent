defmodule Nex.Agent.Tool.WebSearch do
  @moduledoc """
  Web Search Tool - Search the web using Brave Search API
  """

  @behaviour Nex.Agent.Tool

  def name, do: "web_search"
  def description, do: "Search the web. Returns titles, URLs, and snippets."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query"
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of results (1-10)",
          "minimum" => 1,
          "maximum" => 10
        }
      },
      "required" => ["query"]
    }
  end

  def execute(%{"query" => query, "count" => count}, _opts) when is_integer(count) do
    do_search(query, count)
  end

  def execute(%{"query" => query}, _opts) do
    do_search(query, 5)
  end

  defp do_search(query, count) do
    api_key = Application.get_env(:nex_agent, :brave_api_key)

    if is_nil(api_key) or api_key == "" do
      {:ok, %{error: "Brave Search API key not configured. Set :brave_api_key in config."}}
    else
      url = "https://api.search.brave.com/res/v1/web/search"

      headers = [
        {"Accept", "application/json"},
        {"X-Subscription-Token", api_key}
      ]

      params = %{
        "q" => query,
        "count" => count
      }

      case Req.get(url, headers: headers, params: params, follow_redirects: true) do
        {:ok, %{status: 200, body: body}} ->
          results = parse_results(body)
          {:ok, results}

        {:ok, %{status: status, body: body}} ->
          {:ok, %{error: "Search failed with status #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:ok, %{error: "Search failed: #{inspect(reason)}"}}
      end
    end
  end

  defp parse_results(body) do
    web_results = body["web"] || %{}
    results = web_results["results"] || []

    formatted =
      Enum.map(results, fn r ->
        title = r["title"] || ""
        url = r["url"] || ""
        desc = r["description"] || ""
        "#{title}\n#{url}\n#{desc}\n"
      end)
      |> Enum.join("\n---\n")

    if formatted == "" do
      "No results found."
    else
      formatted
    end
  end
end
