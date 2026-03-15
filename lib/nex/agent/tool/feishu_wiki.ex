defmodule Nex.Agent.Tool.FeishuWiki do
  @moduledoc """
  Feishu Wiki tool - Manage knowledge base (Wiki).

  Based on OpenClaw's feishu_wiki_* tools.

  Actions: space_list, space_create, node_list, node_create, node_get, node_update, node_delete
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_wiki"
  def description, do: "Manage Feishu Wiki knowledge base."
  def category, do: :Base

  def definition do
    %{
      name: "feishu_wiki",
      description: """
      飞书知识库（Wiki）管理工具。

      ## Actions

      ### 知识空间
      - **space_list**: 列出知识空间
      - **space_create**: 创建知识空间
      - **space_get**: 获取知识空间详情

      ### 知识节点
      - **node_list**: 列出知识节点
      - **node_create**: 创建知识节点（文档）
      - **node_get**: 获取节点详情
      - **node_update**: 更新节点内容
      - **node_delete**: 删除节点

      ## 注意事项

      - 知识空间是 Wiki 的顶层组织
      - 知识节点可以关联到文档
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: [
              "space_list",
              "space_create",
              "space_get",
              "node_list",
              "node_create",
              "node_get",
              "node_update",
              "node_delete"
            ],
            description: "操作类型"
          },
          "space_id" => %{
            type: "string",
            description: "知识空间ID（node操作时使用）"
          },
          "node_token" => %{
            type: "string",
            description: "知识节点token（node操作时使用）"
          },
          "name" => %{
            type: "string",
            description: "名称（space_create/node_create时使用）"
          },
          "parent_node_token" => %{
            type: "string",
            description: "父节点token（创建子节点时使用）"
          },
          "obj_type" => %{
            type: "string",
            enum: ["doc", "sheet", "bitable", "mindnote", "docx"],
            description: "关联对象类型（node_create时使用）"
          },
          "obj_token" => %{
            type: "string",
            description: "关联对象token（node_create时使用）"
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小（list时使用）"
          },
          "page_token" => %{
            type: "string",
            description: "分页标记（list时使用）"
          },
          "content" => %{
            type: "string",
            description: "要写入的内容（node_update时使用）"
          },
          "update_mode" => %{
            type: "string",
            enum: ["append", "overwrite"],
            description: "更新模式：append追加或overwrite覆盖（node_update时使用）"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "space_list" -> list_spaces(args)
      "space_create" -> create_space(args)
      "space_get" -> get_space(args)
      "node_list" -> list_nodes(args)
      "node_create" -> create_node(args)
      "node_get" -> get_node(args)
      "node_update" -> update_node(args)
      "node_delete" -> delete_node(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # Space operations
  defp list_spaces(args) do
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/wiki/v2/spaces", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           spaces: Enum.map(items, &format_space/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp create_space(args) do
    name = Map.get(args, "name", "新知识空间")

    body = %{"space" => %{"name" => name, "space_type" => "wiki"}}

    case Api.post("/wiki/v2/spaces", body) do
      {:ok, data} ->
        space = Map.get(data, "space", %{})

        {:ok,
         %{
           space_id: Map.get(space, "space_id"),
           name: name,
           node_id: Map.get(space, "root_node_id")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_space(args) do
    space_id = Map.get(args, "space_id")
    if is_nil(space_id), do: {:error, "space_id is required"}, else: do_get_space(space_id)
  end

  defp do_get_space(space_id) do
    case Api.get("/wiki/v2/spaces/#{space_id}") do
      {:ok, data} -> {:ok, %{space: Map.get(data, "space", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Node operations
  defp list_nodes(args) do
    space_id = Map.get(args, "space_id")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    if is_nil(space_id),
      do: {:error, "space_id is required"},
      else: do_list_nodes(space_id, page_size, page_token)
  end

  defp do_list_nodes(space_id, page_size, page_token) do
    params = [{"page_size", page_size}] |> maybe_add_param("page_token", page_token)

    case Api.get("/wiki/v2/spaces/#{space_id}/nodes", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           nodes: Enum.map(items, &format_node/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp create_node(args) do
    space_id = Map.get(args, "space_id")
    parent_node_token = Map.get(args, "parent_node_token")
    obj_type = Map.get(args, "obj_type", "doc")
    name = Map.get(args, "name", "新文档")

    if is_nil(space_id),
      do: {:error, "space_id is required"},
      else: do_create_node(space_id, parent_node_token, obj_type, name)
  end

  defp do_create_node(space_id, parent_node_token, obj_type, name) do
    # First create a document
    case Api.post("/docx/v1/documents", %{"document" => %{"title" => name}}) do
      {:ok, data} ->
        doc_token = get_in(data, ["document", "document_id"])

        # Then create wiki node linking to the document
        body = %{
          "node" => %{
            "obj_type" => obj_type,
            "obj_token" => doc_token,
            "parent_node_token" => parent_node_token || "",
            "space_id" => space_id
          }
        }

        case Api.post("/wiki/v2/spaces/#{space_id}/nodes", body) do
          {:ok, node_data} ->
            node = Map.get(node_data, "node", %{})

            {:ok,
             %{
               node_token: Map.get(node, "node_token"),
               node_id: Map.get(node, "node_id"),
               document_id: doc_token,
               url: "https://feishu.cn/wiki/#{Map.get(node, "node_token")}"
             }}

          {:error, reason} ->
            {:error, format_error(reason)}
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_node(args) do
    space_id = Map.get(args, "space_id")
    node_token = Map.get(args, "node_token")

    if is_nil(space_id) or is_nil(node_token),
      do: {:error, "space_id and node_token are required"},
      else: do_get_node(space_id, node_token)
  end

  defp do_get_node(space_id, node_token) do
    case Api.get("/wiki/v2/spaces/#{space_id}/nodes/#{node_token}") do
      {:ok, data} -> {:ok, %{node: Map.get(data, "node", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp update_node(args) do
    space_id = Map.get(args, "space_id")
    node_token = Map.get(args, "node_token")
    content = Map.get(args, "content", "")
    update_mode = Map.get(args, "update_mode", "append")

    if is_nil(space_id) or is_nil(node_token),
      do: {:error, "space_id and node_token are required"},
      else: do_update_node(space_id, node_token, content, update_mode)
  end

  defp do_update_node(space_id, node_token, content, update_mode) do
    case Api.get("/wiki/v2/spaces/#{space_id}/nodes/#{node_token}") do
      {:ok, data} ->
        node = Map.get(data, "node", %{})
        obj_token = Map.get(node, "obj_token")
        obj_type = Map.get(node, "obj_type", "doc")

        if is_nil(obj_token) do
          {:error, "Wiki节点未关联文档，无法更新"}
        else
          doc_id = obj_token
          blocks = convert_to_paragraph_blocks(content)

          result =
            case update_mode do
              "overwrite" -> update_wiki_doc_overwrite(doc_id, blocks)
              _ -> update_wiki_doc_append(doc_id, blocks)
            end

          case result do
            {:ok, _} ->
              {:ok,
               %{
                 node_token: node_token,
                 document_id: doc_id,
                 obj_type: obj_type,
                 message: "Wiki节点关联文档更新成功"
               }}

            {:error, reason} ->
              {:error, format_error(reason)}
          end
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp update_wiki_doc_append(doc_id, blocks) do
    Api.post("/docx/v1/documents/#{doc_id}/blocks", %{"children" => blocks})
  end

  defp update_wiki_doc_overwrite(doc_id, blocks) do
    case Api.get("/docx/v1/documents/#{doc_id}/blocks", params: [{"page_size", 100}]) do
      {:ok, blocks_data} ->
        items = get_in(blocks_data, ["data", "items"]) || []
        block_ids = Enum.map(items, &Map.get(&1, "block_id"))

        Enum.each(block_ids, fn block_id ->
          Api.delete("/docx/v1/documents/#{doc_id}/blocks/#{block_id}")
        end)

        Api.post("/docx/v1/documents/#{doc_id}/blocks", %{"children" => blocks})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_to_paragraph_blocks(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(fn line ->
      %{
        "block_type" => "2",
        "paragraph" => %{"elements" => [%{"text_run" => %{"content" => line}}]}
      }
    end)
  end

  defp convert_to_paragraph_blocks(_), do: []

  defp delete_node(args) do
    space_id = Map.get(args, "space_id")
    node_token = Map.get(args, "node_token")

    if is_nil(space_id) or is_nil(node_token),
      do: {:error, "space_id and node_token are required"},
      else: do_delete_node(space_id, node_token)
  end

  defp do_delete_node(space_id, node_token) do
    case Api.delete("/wiki/v2/spaces/#{space_id}/nodes/#{node_token}") do
      {:ok, _data} -> {:ok, %{success: true, node_token: node_token}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp format_space(space) do
    %{
      space_id: Map.get(space, "space_id"),
      name: Map.get(space, "name"),
      node_count: Map.get(space, "node_count"),
      space_type: Map.get(space, "space_type")
    }
  end

  defp format_node(node) do
    %{
      node_token: Map.get(node, "node_token"),
      node_id: Map.get(node, "node_id"),
      name: Map.get(node, "name"),
      obj_type: Map.get(node, "obj_type"),
      obj_token: Map.get(node, "obj_token"),
      parent_node_token: Map.get(node, "parent_node_token")
    }
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, to_string(value)}]

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
