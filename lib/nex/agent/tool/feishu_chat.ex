defmodule Nex.Agent.Tool.FeishuChat do
  @moduledoc """
  Feishu Chat tool - Manage chat groups and members.

  Based on OpenClaw's feishu_chat_* tools.

  Actions: chat_search, chat_get, chat_members_add, chat_members_remove, chat_members_list
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Feishu.Api

  def name, do: "feishu_chat"
  def description, do: "Manage Feishu chat groups and members."
  def category, do: :Base

  def definition do
    %{
      name: "feishu_chat",
      description: """
      飞书群聊管理工具。

      ## Actions

      - **chat_search**: 搜索群聊
      - **chat_get**: 获取群详情
      - **chat_members_add**: 添加群成员
      - **chat_members_remove**: 移除群成员
      - **chat_members_list**: 列出群成员

      ## 注意事项

      - chat_id 格式：oc_xxx
      - user_id 格式：ou_xxx
      """,
      parameters: %{
        type: "object",
        properties: %{
          "action" => %{
            type: "string",
            enum: [
              "chat_search",
              "chat_get",
              "chat_members_add",
              "chat_members_remove",
              "chat_members_list"
            ],
            description: "操作类型"
          },
          "chat_id" => %{
            type: "string",
            description: "群ID（chat_get/members操作时使用）"
          },
          "query" => %{
            type: "string",
            description: "搜索关键词（chat_search时使用）"
          },
          "member_id_type" => %{
            type: "string",
            enum: ["open_id", "union_id", "user_id"],
            description: "成员ID类型"
          },
          "member_ids" => %{
            type: "array",
            description: "成员ID列表（members_add/remove时使用）",
            items: %{type: "string"}
          },
          "page_size" => %{
            type: "integer",
            description: "分页大小"
          },
          "page_token" => %{
            type: "string",
            description: "分页标记"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(args, _ctx) do
    action = Map.get(args, "action")

    case action do
      "chat_search" -> search_chats(args)
      "chat_get" -> get_chat(args)
      "chat_members_add" -> add_members(args)
      "chat_members_remove" -> remove_members(args)
      "chat_members_list" -> list_members(args)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # Chat operations
  defp search_chats(args) do
    query = Map.get(args, "query", "")
    page_size = Map.get(args, "page_size", 20)
    page_token = Map.get(args, "page_token")

    body =
      %{"query" => query, "page_size" => page_size}
      |> maybe_add("page_token", page_token)

    case Api.post("/im/v1/chats/search", body) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           chats: Enum.map(items, &format_chat/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp get_chat(args) do
    chat_id = Map.get(args, "chat_id")
    if is_nil(chat_id), do: {:error, "chat_id is required"}, else: do_get_chat(chat_id)
  end

  defp do_get_chat(chat_id) do
    case Api.get("/im/v1/chats/#{chat_id}") do
      {:ok, data} -> {:ok, %{chat: Map.get(data, "chat", %{})}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # Member operations
  defp add_members(args) do
    chat_id = Map.get(args, "chat_id")
    member_ids = Map.get(args, "member_ids", [])
    member_id_type = Map.get(args, "member_id_type", "open_id")

    if is_nil(chat_id) or member_ids == [],
      do: {:error, "chat_id and member_ids are required"},
      else: do_add_members(chat_id, member_ids, member_id_type)
  end

  defp do_add_members(chat_id, member_ids, member_id_type) do
    body = %{
      "member_id_type" => member_id_type,
      "members" => Enum.map(member_ids, &%{"member_id" => &1})
    }

    case Api.post("/im/v1/chats/#{chat_id}/members", body) do
      {:ok, _data} -> {:ok, %{success: true, members_added: length(member_ids)}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp remove_members(args) do
    chat_id = Map.get(args, "chat_id")
    member_ids = Map.get(args, "member_ids", [])
    member_id_type = Map.get(args, "member_id_type", "open_id")

    if is_nil(chat_id) or member_ids == [],
      do: {:error, "chat_id and member_ids are required"},
      else: do_remove_members(chat_id, member_ids, member_id_type)
  end

  defp do_remove_members(chat_id, member_ids, member_id_type) do
    results =
      Enum.map(member_ids, fn member_id ->
        case Api.delete(
               "/im/v1/chats/#{chat_id}/members/#{member_id}?member_id_type=#{member_id_type}"
             ) do
          {:ok, _} -> {:ok, member_id}
          {:error, reason} -> {:error, {member_id, reason}}
        end
      end)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    if errors == [],
      do: {:ok, %{success: true, members_removed: length(member_ids)}},
      else: {:error, format_error(Enum.map(errors, fn {:error, {_, r}} -> r end))}
  end

  defp list_members(args) do
    chat_id = Map.get(args, "chat_id")
    member_id_type = Map.get(args, "member_id_type", "open_id")
    page_size = Map.get(args, "page_size", 50)
    page_token = Map.get(args, "page_token")

    if is_nil(chat_id),
      do: {:error, "chat_id is required"},
      else: do_list_members(chat_id, member_id_type, page_size, page_token)
  end

  defp do_list_members(chat_id, member_id_type, page_size, page_token) do
    params =
      [{"member_id_type", member_id_type}, {"page_size", page_size}]
      |> maybe_add_param("page_token", page_token)

    case Api.get("/im/v1/chats/#{chat_id}/members", params: params) do
      {:ok, data} ->
        items = Map.get(data, "items", [])

        {:ok,
         %{
           members: Enum.map(items, &format_member/1),
           has_more: Map.get(data, "has_more", false),
           page_token: Map.get(data, "page_token")
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp format_chat(chat) do
    %{
      chat_id: Map.get(chat, "chat_id"),
      name: Map.get(chat, "name"),
      avatar: Map.get(chat, "avatar"),
      owner_id: Map.get(chat, "owner_id"),
      owner_id_type: Map.get(chat, "owner_id_type"),
      external: Map.get(chat, "external"),
      tenant_key: Map.get(chat, "tenant_key")
    }
  end

  defp format_member(member) do
    %{
      member_id: Map.get(member, "member_id"),
      member_id_type: Map.get(member, "member_id_type"),
      name: Map.get(member, "name"),
      avatar: Map.get(member, "avatar")
    }
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, to_string(value)}]

  defp format_error(%{code: code, message: msg}), do: "Feishu API error #{code}: #{msg}"
  defp format_error(%{code: code}), do: "Feishu API error #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Error: #{inspect(reason)}"
end
