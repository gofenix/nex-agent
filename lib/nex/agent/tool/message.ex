defmodule Nex.Agent.Tool.Message do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "message"
  def description, do: "Send a message to the user immediately."
  def category, do: :base

  def definition do
    %{
      name: "message",
      description:
        "Send a message to the user. Use this when you want to communicate something immediately. For Feishu, you can send structured native message types by providing msg_type plus content_json.",
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The message content to send"},
          msg_type: %{
            type: "string",
            description:
              "Optional explicit message type for channels that support structured messages, such as Feishu. Feishu examples: text, post, interactive, image, file, audio, media, sticker, share_chat, share_user, system."
          },
          content_json: %{
            type: ["object", "string"],
            description:
              "Optional structured message payload. For Feishu this should be the raw content JSON object/string for the specified msg_type. Examples: image => {image_key}, file/audio/media/sticker => {file_key}, share_chat => {chat_id}, share_user => {user_id}, text => {text}, system => {type, params}."
          },
          receive_id_type: %{
            type: "string",
            description:
              "Optional explicit recipient ID type for Feishu (open_id, chat_id, user_id, union_id, email)."
          },
          channel: %{
            type: "string",
            description:
              "Target channel (telegram, feishu, discord, http). Defaults to current channel."
          },
          chat_id: %{
            type: "string",
            description: "Target chat/user ID. Defaults to current chat."
          }
        },
        required: ["content"]
      }
    }
  end

  def execute(args, ctx) do
    require Logger
    Logger.info("Message Tool Execute - Args: #{inspect(args)}, Ctx: #{inspect(ctx)}")

    content = Map.get(args, "content")
    channel = Map.get(args, "channel") || Map.get(ctx, :channel, "telegram")
    chat_id = Map.get(args, "chat_id") || Map.get(ctx, :chat_id, "")
    msg_type = Map.get(args, "msg_type")
    content_json = Map.get(args, "content_json")
    receive_id_type = Map.get(args, "receive_id_type")

    if content || content_json do
      topic =
        case channel do
          "telegram" -> :telegram_outbound
          "feishu" -> :feishu_outbound
          "discord" -> :discord_outbound
          "http" -> :http_outbound
          _ -> :outbound
        end

      metadata =
        Map.get(ctx, :metadata, %{})
        |> Map.put("_from_tool", true)
        |> maybe_put("msg_type", msg_type)
        |> maybe_put("content_json", content_json)
        |> maybe_put("receive_id_type", receive_id_type)

      payload = %{
        chat_id: chat_id,
        content: content,
        metadata: metadata
      }

      Logger.info("Message Tool Publishing to #{topic}: #{inspect(payload)}")

      Nex.Agent.Bus.publish(topic, payload)

      {:ok, %{sent: true, channel: channel, chat_id: chat_id}}
    else
      {:error, "content or content_json is required"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
