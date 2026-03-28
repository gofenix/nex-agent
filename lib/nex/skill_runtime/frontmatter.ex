defmodule Nex.SkillRuntime.Frontmatter do
  @moduledoc false

  @spec parse_document(String.t()) :: {map(), String.t()}
  def parse_document(content) when is_binary(content) do
    case Regex.run(~r/^---\n(.*?)\n---\n?(.*)$/s, content) do
      [_, frontmatter, body] -> {parse(frontmatter), body}
      nil -> {%{}, content}
    end
  end

  @spec parse(String.t()) :: map()
  def parse(""), do: %{}

  def parse(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> parse_yaml_block(0)
  end

  defp parse_yaml_block(lines, indent) do
    {result, _rest} = do_parse_yaml_block(lines, indent, %{})
    result
  end

  defp do_parse_yaml_block([], _indent, acc), do: {acc, []}

  defp do_parse_yaml_block([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        do_parse_yaml_block(rest, indent, acc)

      current_indent < indent ->
        {acc, [line | rest]}

      String.starts_with?(trimmed, "- ") ->
        {acc, [line | rest]}

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [key, ""] ->
            next_line = List.first(rest)

            {value, remaining} =
              cond do
                is_nil(next_line) or indentation(next_line) <= current_indent ->
                  {"", rest}

                String.trim(next_line) in ["|", ">"] ->
                  parse_yaml_multiline(
                    tl(rest),
                    indentation(next_line) + 2,
                    block_scalar_style(String.trim(next_line))
                  )

                String.starts_with?(String.trim(next_line), "- ") ->
                  parse_yaml_list(rest, current_indent + 2)

                true ->
                  do_parse_yaml_block(rest, current_indent + 2, %{})
              end

            do_parse_yaml_block(remaining, indent, Map.put(acc, key, value))

          [key, value] ->
            value = String.trim(value)

            {parsed, remaining} =
              case value do
                "|" -> parse_yaml_multiline(rest, current_indent + 2, :literal)
                ">" -> parse_yaml_multiline(rest, current_indent + 2, :folded)
                _ -> {parse_scalar(value), rest}
              end

            do_parse_yaml_block(remaining, indent, Map.put(acc, key, parsed))
        end
    end
  end

  defp parse_yaml_list(lines, indent), do: do_parse_yaml_list(lines, indent, [])

  defp do_parse_yaml_list([], _indent, acc), do: {Enum.reverse(acc), []}

  defp do_parse_yaml_list([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" ->
        do_parse_yaml_list(rest, indent, acc)

      current_indent < indent or not String.starts_with?(trimmed, "- ") ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        item =
          trimmed
          |> String.replace_prefix("- ", "")
          |> String.trim()
          |> parse_scalar()

        do_parse_yaml_list(rest, indent, [item | acc])
    end
  end

  defp parse_yaml_multiline(lines, indent, style) do
    {block_lines, remaining} = take_yaml_multiline(lines, indent, [])

    value =
      case style do
        :literal -> Enum.join(block_lines, "\n")
        :folded -> fold_yaml_lines(block_lines)
      end

    {String.trim_trailing(value), remaining}
  end

  defp take_yaml_multiline([], _indent, acc), do: {Enum.reverse(acc), []}

  defp take_yaml_multiline([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" ->
        take_yaml_multiline(rest, indent, ["" | acc])

      current_indent < indent ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        content =
          if String.length(line) >= indent do
            String.slice(line, indent..-1//1)
          else
            trimmed
          end

        take_yaml_multiline(rest, indent, [String.trim_trailing(content) | acc])
    end
  end

  defp fold_yaml_lines(lines) do
    Enum.reduce(lines, "", fn
      "", "" -> ""
      "", acc -> acc <> "\n\n"
      line, "" -> line
      line, acc -> if String.ends_with?(acc, "\n\n"), do: acc <> line, else: acc <> " " <> line
    end)
  end

  defp block_scalar_style("|"), do: :literal
  defp block_scalar_style(">"), do: :folded

  defp indentation(line) do
    String.length(line) - String.length(String.trim_leading(line))
  end

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("null"), do: nil

  defp parse_scalar(value) do
    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") do
      case Jason.decode(value) do
        {:ok, decoded} -> decoded
        _ -> value
      end
    else
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> value
      end
    end
  end
end
