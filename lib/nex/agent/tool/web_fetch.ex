defmodule Nex.Agent.Tool.WebFetch do
  @moduledoc """
  Web Fetch Tool - Fetch URL content with HTML parsing
  """

  @behaviour Nex.Agent.Tool.Behaviour

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @max_length 50_000

  def name, do: "web_fetch"
  def description, do: "Fetch and extract content from a URL."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "URL to fetch"
          }
        },
        required: ["url"]
      }
    }
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "URL to fetch"
        }
      },
      "required" => ["url"]
    }
  end

  def execute(%{"url" => url}, _opts) do
    if valid_url?(url) do
      do_fetch(url)
    else
      {:ok, %{error: "Invalid URL: #{url}"}}
    end
  end

  defp valid_url?(url) do
    case URI.parse(url) do
      %{scheme: s, host: h} when s in ["http", "https"] and h != nil -> true
      _ -> false
    end
  end

  defp do_fetch(url) do
    headers = [
      {"User-Agent", @user_agent},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"}
    ]

    case Req.get(url, headers: headers, max_redirects: 5, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        content = extract_content(body, url)
        {:ok, content}

      {:ok, %{status: status}} ->
        {:ok, %{error: "Failed to fetch: HTTP #{status}"}}

      {:error, reason} ->
        {:ok, %{error: "Failed to fetch: #{inspect(reason)}"}}
    end
  end

  defp extract_content(html, url) when is_binary(html) do
    html
    |> strip_scripts()
    |> strip_styles()
    |> strip_tags()
    |> decode_entities()
    |> normalize_whitespace()
    |> truncate(@max_length)
    |> format_output(url)
  end

  defp strip_scripts(html) do
    Regex.replace(~r/<script[^>]*>[\s\S]*?<\/script>/i, html, "")
  end

  defp strip_styles(html) do
    Regex.replace(~r/<style[^>]*>[\s\S]*?<\/style>/i, html, "")
  end

  defp strip_tags(html) do
    html
    |> Regex.replace(~r/<[\s\S]*?>/, " ")
    |> String.replace(Regex.replace(~r/<\/[\s\S]*?>/, html, " "), " ")
  end

  defp decode_entities(html) do
    html
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/&#\d+;/, " ")
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "\n\n... [truncated]"
    else
      text
    end
  end

  defp format_output(content, url) do
    """
    Source: #{url}

    #{content}
    """
  end
end
