defmodule Nex.Agent.Tool.FeishuSearch do
  @moduledoc """
  Feishu Search tool - Search documents and wikis.

  Based on OpenClaw's feishu_search_doc_wiki tool.

  Uses the Feishu Search API:
  - search: POST /open-apis/search/v2/doc_wiki/search
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_search"
  def description, do: "Search Feishu documents and wikis."
  def category, do: :base

  def definition do
    %{
      name: "feishu_search",
      description: """
      飞书文档与知识库统一搜索工具。同时搜索云空间文档和知识库 Wiki。

      ## 功能

      - 支持关键词搜索
      - 支持按文档类型筛选（doc/docx/sheet/bitable/wiki等）
      - 支持按创建者筛选
      - 支持按时间范围筛选

      ## 返回结果

      - 标题和摘要高亮（<h>标签包裹匹配关键词）
      - 文档token和类型
      - 创建者、编辑时间等信息
      """,
      parameters: %{
        type: "object",
        properties: %{
          "query" => %{
            type: "string",
            description: "搜索关键词（可选，不传则返回最近浏览的文档）",
            maxLength: 50
          },
          "doc_types" => %{
            type: "array",
            items: %{
              type: "string",
              enum: [
                "DOC",
                "DOCX",
                "SHEET",
                "BITABLE",
                "MINDNOTE",
                "FILE",
                "WIKI",
                "FOLDER",
                "SLIDES"
              ]
            },
            description: "文档类型列表（可选）",
            maxItems: 10
          },
          "creator_ids" => %{
            type: "array",
            items: %{type: "string"},
            description: "创建者 OpenID 列表（可选，最多20个）",
            maxItems: 20
          },
          "sort_type" => %{
            type: "string",
            enum: ["DEFAULT_TYPE", "EDIT_TIME", "EDIT_TIME_ASC", "CREATE_TIME", "OPEN_TIME"],
            description: "排序方式（可选，默认EDIT_TIME）"
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小（可选，默认15，最大20）",
            minimum: 1,
            maximum: 20
          },
          "page_token" => %{
            type: "string",
            description: "分页标记（可选）"
          }
        },
        required: []
      }
    }
  end

  def execute(args, _ctx) do
    query = Map.get(args, "query", "")
    doc_types = Map.get(args, "doc_types")
    creator_ids = Map.get(args, "creator_ids")
    sort_type = Map.get(args, "sort_type", "EDIT_TIME")
    page_size = Map.get(args, "page_size", 15)
    page_token = Map.get(args, "page_token")

    body =
      %{
        "query" => query,
        "page_size" => page_size
      }
      |> maybe_add("page_token", page_token)
      |> add_filters(doc_types, creator_ids, sort_type)

    case Api.post("/search/v2/doc_wiki/search", body) do
      {:ok, data} ->
        results = Map.get(data, "res_units", [])
        total = Map.get(data, "total", 0)
        has_more = Map.get(data, "has_more", false)
        next_token = Map.get(data, "page_token")

        {:ok,
         %{
           total: total,
           has_more: has_more,
           page_token: next_token,
           results: Enum.map(results, &format_search_result/1)
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp add_filters(body, nil, nil, _sort_type), do: body

  defp add_filters(body, doc_types, creator_ids, sort_type) do
    doc_filter = build_filter(doc_types, creator_ids, sort_type)
    wiki_filter = build_filter(doc_types, creator_ids, sort_type)

    body
    |> Map.put("doc_filter", doc_filter)
    |> Map.put("wiki_filter", wiki_filter)
  end

  defp build_filter(doc_types, creator_ids, sort_type) do
    filter =
      %{}
      |> maybe_add("doc_types", doc_types)
      |> maybe_add("creator_ids", creator_ids)
      |> maybe_add("sort_type", sort_type)

    if map_size(filter) > 0, do: filter, else: %{}
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp format_search_result(result) do
    %{
      document_id: Map.get(result, "token") || Map.get(result, "doc_token"),
      title: Map.get(result, "title", ""),
      snippet: Map.get(result, "snippet", ""),
      doc_type: Map.get(result, "doc_type", ""),
      url: Map.get(result, "url", ""),
      creator_id: get_in(result, ["creator", "id"]),
      creator_name: get_in(result, ["creator", "name"]),
      edited_time: Map.get(result, "edited_time", ""),
      created_time: Map.get(result, "created_time", "")
    }
  end

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
