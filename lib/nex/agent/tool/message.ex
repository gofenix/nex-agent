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
        "Send a message to the user. Use this when you want to communicate something immediately. For Feishu, you can send structured native message types by providing msg_type plus content_json, upload and send a local PNG/JPEG via local_image_path, or provide both content and local_image_path to send a short text followed by the image.",
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
          local_image_path: %{
            type: "string",
            description:
              "Optional absolute or workspace-relative path to a local image file. For Feishu, the runtime uploads it and sends a native image message. If content or content_json is also present, Feishu sends that message first and then the image."
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
        description: "Provide at least one of content, content_json, or local_image_path.",
        required: []
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
    local_image_path = Map.get(args, "local_image_path")
    receive_id_type = Map.get(args, "receive_id_type")
    has_local_image = is_binary(local_image_path) and local_image_path != ""
    has_message_payload = present_message_payload?(content, content_json)

    if has_message_payload || has_local_image do
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

      case channel do
        "feishu" ->
          cond do
            has_local_image and has_message_payload ->
              if Process.whereis(Nex.Agent.Channel.Feishu) do
                with :ok <-
                       Nex.Agent.Channel.Feishu.deliver_message(
                         chat_id,
                         content,
                         feishu_companion_metadata(metadata)
                       ),
                     :ok <-
                       Nex.Agent.Channel.Feishu.deliver_local_image(
                         chat_id,
                         local_image_path,
                         metadata
                       ) do
                  {:ok,
                   %{
                     sent: true,
                     channel: channel,
                     chat_id: chat_id,
                     delivered: ["message", "image"]
                   }}
                else
                  {:error, reason} ->
                    {:error, "Feishu text+image send failed: #{inspect(reason)}"}
                end
              else
                {:error, "Feishu text+image send requires the Feishu channel process to be running"}
              end

            has_local_image ->
              if Process.whereis(Nex.Agent.Channel.Feishu) do
                case Nex.Agent.Channel.Feishu.deliver_local_image(
                       chat_id,
                       local_image_path,
                       metadata
                     ) do
                  :ok ->
                    {:ok, %{sent: true, channel: channel, chat_id: chat_id}}

                  {:error, reason} ->
                    {:error, "Feishu image send failed: #{inspect(reason)}"}
                end
              else
                {:error, "Feishu image send requires the Feishu channel process to be running"}
              end

            Process.whereis(Nex.Agent.Channel.Feishu) ->
              case Nex.Agent.Channel.Feishu.deliver_message(chat_id, content, metadata) do
                :ok ->
                  {:ok, %{sent: true, channel: channel, chat_id: chat_id}}

                {:error, reason} ->
                  {:error, "Feishu send failed: #{inspect(reason)}"}
              end

            true ->
              Nex.Agent.Bus.publish(topic, payload)
              {:ok, %{sent: true, channel: channel, chat_id: chat_id}}
          end

        _ ->
          if is_binary(local_image_path) and local_image_path != "" do
            {:error, "local_image_path is currently only supported for Feishu"}
          else
            Nex.Agent.Bus.publish(topic, payload)
            {:ok, %{sent: true, channel: channel, chat_id: chat_id}}
          end
      end
    else
      {:error, "content, content_json, or local_image_path is required"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_message_payload?(content, content_json) do
    (is_binary(content) and String.trim(content) != "") or not is_nil(content_json)
  end

  defp feishu_companion_metadata(metadata) do
    msg_type = Map.get(metadata, "msg_type")
    content_json = Map.get(metadata, "content_json")

    if (is_nil(msg_type) or msg_type == "") and is_nil(content_json) do
      Map.put(metadata, "msg_type", "text")
    else
      metadata
    end
  end
end
