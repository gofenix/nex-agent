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
    proxy_url =
      System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") ||
        System.get_env("HTTP_PROXY") || System.get_env("http_proxy")

    if proxy_url && proxy_url != "" do
      case URI.parse(proxy_url) do
        %URI{scheme: scheme, host: host, port: port}
        when is_binary(host) and host != "" ->
          proxy_scheme = if scheme in ["https", "HTTPS"], do: :https, else: :http

          proxy_port =
            if port && port > 0, do: port, else: if(proxy_scheme == :https, do: 443, else: 80)

          Keyword.put(opts, :connect_options,
            proxy: {proxy_scheme, String.to_charlist(host), proxy_port, []}
          )

        _ ->
          opts
      end
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
