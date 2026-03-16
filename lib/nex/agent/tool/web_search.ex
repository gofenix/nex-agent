defmodule Nex.Agent.Tool.WebSearch do
  @moduledoc """
  Web Search Tool - Search the web using DuckDuckGo Instant Answer API (free, no API key required)
  """

  @behaviour Nex.Agent.Tool.Behaviour

  @ddg_url "https://api.duckduckgo.com"

  def name, do: "web_search"
  def description, do: "Search the web. Returns titles, URLs, and snippets."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Search query"
          },
          count: %{
            type: "integer",
            description: "Number of results (1-10)",
            minimum: 1,
            maximum: 10
          }
        },
        required: ["query"]
      }
    }
  end

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
    params = %{
      "q" => query,
      "format" => "json",
      "no_html" => 1,
      "skip_disambig" => 1,
      "count" => count
    }

    req_opts = [params: params, follow_redirects: true]
    req_opts = maybe_add_proxy(req_opts)

    case Req.get(@ddg_url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_results(body)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:ok, %{error: "Search failed with status #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        {:ok, %{error: "Search failed: #{inspect(reason)}"}}
    end
  end

  defp maybe_add_proxy(opts) do
    proxy =
      System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") ||
        System.get_env("HTTP_PROXY") || System.get_env("http_proxy")

    if proxy && proxy != "" do
      Keyword.put(opts, :proxy, proxy)
    else
      opts
    end
  end

  defp parse_results(body) do
    results = body["RelatedTopics"] || []

    formatted =
      Enum.map_join(results, "\n---\n", fn r ->
        title = r["Text"] || r["name"] || ""
        url = r["FirstURL"] || r["url"] || ""
        "#{title}\n#{url}\n"
      end)

    if formatted == "" do
      "No results found."
    else
      formatted
    end
  end
end
