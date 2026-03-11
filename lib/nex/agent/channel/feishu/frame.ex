defmodule Nex.Agent.Channel.Feishu.Frame do
  @moduledoc """
  Feishu WebSocket binary frame codec (pbbp2 protobuf protocol).

  Frame protobuf fields:
    1: SeqID    (uint64)
    2: LogID    (uint64)
    3: service  (int32)
    4: method   (int32)  — 0=control, 1=data
    5: headers  (repeated message Header)
    8: payload  (bytes)

  Header protobuf fields:
    1: key   (string)
    2: value (string)
  """

  import Bitwise

  defstruct seq_id: 0,
            log_id: 0,
            service: 0,
            method: 0,
            headers: [],
            payload: <<>>

  @type t :: %__MODULE__{
          seq_id: non_neg_integer(),
          log_id: non_neg_integer(),
          service: integer(),
          method: integer(),
          headers: [{String.t(), String.t()}],
          payload: binary()
        }

  @method_control 0
  @method_data 1

  def method_control, do: @method_control
  def method_data, do: @method_data

  @doc "Decode a binary Protobuf frame."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    frame = decode_frame(binary)
    {:ok, frame}
  rescue
    e -> {:error, e}
  end

  @doc "Encode a frame struct to binary Protobuf."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = frame) do
    buf = <<>>
    buf = buf <> encode_uint64(1, frame.seq_id)
    buf = buf <> encode_uint64(2, frame.log_id)
    buf = buf <> encode_int32(3, frame.service)
    buf = buf <> encode_int32(4, frame.method)

    buf =
      Enum.reduce(frame.headers, buf, fn {k, v}, acc ->
        header_bytes = encode_string(1, k) <> encode_string(2, v)
        acc <> encode_bytes(5, header_bytes)
      end)

    buf =
      if byte_size(frame.payload) > 0 do
        buf <> encode_bytes(8, frame.payload)
      else
        buf
      end

    buf
  end

  @doc "Get a header value by key."
  @spec get_header(t(), String.t()) :: String.t() | nil
  def get_header(%__MODULE__{headers: headers}, key) do
    case List.keyfind(headers, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  # ─── Decoder ──────────────────────────────────────────────────────────────

  defp decode_frame(binary) do
    {fields, _rest} = decode_fields(binary, [])

    frame = %__MODULE__{}

    Enum.reduce(fields, frame, fn
      {1, :varint, v}, acc -> %{acc | seq_id: v}
      {2, :varint, v}, acc -> %{acc | log_id: v}
      {3, :varint, v}, acc -> %{acc | service: decode_int32(v)}
      {4, :varint, v}, acc -> %{acc | method: decode_int32(v)}
      {5, :bytes, v}, acc -> %{acc | headers: acc.headers ++ [decode_header(v)]}
      {8, :bytes, v}, acc -> %{acc | payload: v}
      _, acc -> acc
    end)
  end

  defp decode_header(binary) do
    {fields, _} = decode_fields(binary, [])

    key =
      Enum.find_value(fields, "", fn
        {1, :bytes, v} -> v
        _ -> nil
      end)

    value =
      Enum.find_value(fields, "", fn
        {2, :bytes, v} -> v
        _ -> nil
      end)

    {key, value}
  end

  defp decode_fields(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp decode_fields(binary, acc) do
    {tag_wire, rest} = decode_varint(binary)
    field_number = tag_wire >>> 3
    wire_type = tag_wire &&& 0x7

    case wire_type do
      0 ->
        {value, rest2} = decode_varint(rest)
        decode_fields(rest2, [{field_number, :varint, value} | acc])

      2 ->
        {len, rest2} = decode_varint(rest)
        <<value::binary-size(len), rest3::binary>> = rest2

        value =
          if field_number in [1, 2, 5, 6, 7, 8, 9] do
            value
          else
            value
          end

        decode_fields(rest3, [{field_number, :bytes, value} | acc])

      1 ->
        <<_value::little-64, rest2::binary>> = rest
        decode_fields(rest2, acc)

      5 ->
        <<_value::little-32, rest2::binary>> = rest
        decode_fields(rest2, acc)

      _ ->
        {Enum.reverse(acc), <<>>}
    end
  end

  defp decode_varint(binary), do: decode_varint(binary, 0, 0)

  defp decode_varint(<<1::1, byte::7, rest::binary>>, acc, shift) do
    decode_varint(rest, acc ||| byte <<< shift, shift + 7)
  end

  defp decode_varint(<<0::1, byte::7, rest::binary>>, acc, shift) do
    {acc ||| byte <<< shift, rest}
  end

  defp decode_int32(v) when v >= 0x80000000, do: v - 0x100000000
  defp decode_int32(v), do: v

  # ─── Encoder ──────────────────────────────────────────────────────────────

  defp encode_varint(value) when value < 128, do: <<value>>

  defp encode_varint(value) do
    <<1::1, value &&& 0x7F::7>> <> encode_varint(value >>> 7)
  end

  defp encode_tag(field_number, wire_type) do
    encode_varint(field_number <<< 3 ||| wire_type)
  end

  defp encode_uint64(field, value) do
    encode_tag(field, 0) <> encode_varint(value)
  end

  defp encode_int32(field, value) when value < 0 do
    encode_tag(field, 0) <> encode_varint(value + 0x10000000000000000)
  end

  defp encode_int32(field, value) do
    encode_tag(field, 0) <> encode_varint(value)
  end

  defp encode_string(field, value) when is_binary(value) do
    encode_tag(field, 2) <> encode_varint(byte_size(value)) <> value
  end

  defp encode_bytes(field, value) when is_binary(value) do
    encode_tag(field, 2) <> encode_varint(byte_size(value)) <> value
  end
end
