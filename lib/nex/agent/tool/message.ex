defmodule Nex.Agent.Tool.Message do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "message"
  def description, do: "Send a message to the user immediately."
  def category, do: :base

  def definition do
    %{
      name: "message",
      description:
        "Send a message to the user. Use this when you want to communicate something immediately.",
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The message content to send"},
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

    unless content do
      {:error, "content is required"}
    else
      topic =
        case channel do
          "telegram" -> :telegram_outbound
          "feishu" -> :feishu_outbound
          "discord" -> :discord_outbound
          "http" -> :http_outbound
          _ -> :outbound
        end

      metadata = Map.get(ctx, :metadata, %{}) |> Map.put("_from_tool", true)

      payload = %{
        chat_id: chat_id,
        content: content,
        metadata: metadata
      }

      Logger.info("Message Tool Publishing to #{topic}: #{inspect(payload)}")

      Nex.Agent.Bus.publish(topic, payload)

      {:ok, %{sent: true, channel: channel, chat_id: chat_id}}
    end
  end
end
