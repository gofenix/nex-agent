defmodule ReqLLM.Providers.AnthropicDecodeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  test "decode_response returns a structured error for empty-body 200 responses" do
    model = LLMDB.Model.new!(%{id: "kimi-k2.5", provider: :anthropic})

    request = %Req.Request{
      private: %{req_llm_model: model},
      options: %{model: model.id}
    }

    response = %Req.Response{
      status: 200,
      body: "",
      headers: [{"msh-request-id", "req_123"}]
    }

    log =
      capture_log(fn ->
        assert {^request, %ReqLLM.Error.API.Response{} = error} =
                 ReqLLM.Providers.Anthropic.decode_response({request, response})

        assert error.status == 200
        assert error.reason =~ "Anthropic response decode error"
        assert error.reason =~ "empty_body"
        assert error.reason =~ "request_id=req_123"
      end)

    assert log =~ "status=200"
    assert log =~ "body_type=:binary"
    assert log =~ "body_bytes=0"
    assert log =~ ~s(request_id="req_123")
  end
end
