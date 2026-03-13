defmodule Nex.Agent.MessageToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Bus
  alias Nex.Agent.Tool.Message

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    Bus.subscribe(:feishu_outbound)

    on_exit(fn ->
      Bus.unsubscribe(:feishu_outbound)
    end)

    :ok
  end

  test "message tool preserves legacy behavior with plain content" do
    assert {:ok, %{sent: true, channel: "feishu", chat_id: "ou_123"}} =
             Message.execute(
               %{"content" => "hello", "channel" => "feishu", "chat_id" => "ou_123"},
               %{}
             )

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.content == "hello"
    assert payload.metadata["_from_tool"] == true
    refute Map.has_key?(payload.metadata, "msg_type")
  end

  test "message tool forwards explicit feishu structured message metadata" do
    assert {:ok, %{sent: true, channel: "feishu", chat_id: "oc_123"}} =
             Message.execute(
               %{
                 "channel" => "feishu",
                 "chat_id" => "oc_123",
                 "msg_type" => "image",
                 "content_json" => %{"image_key" => "img_123"},
                 "receive_id_type" => "chat_id"
               },
               %{}
             )

    assert_receive {:bus_message, :feishu_outbound, payload}
    assert payload.content == nil
    assert payload.metadata["msg_type"] == "image"
    assert payload.metadata["content_json"] == %{"image_key" => "img_123"}
    assert payload.metadata["receive_id_type"] == "chat_id"
  end
end
