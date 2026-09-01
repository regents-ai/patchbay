defmodule Patchbay.Patchbay.Frontmatter do
  @moduledoc """
  Bounded parser for the string-valued YAML frontmatter used by the demo Skill.

  Patchbay does not execute or evaluate generated Markdown. Keeping this parser
  deliberately small means frontmatter is treated as data, not as an arbitrary
  YAML document with anchors, tags, or executable extensions.
  """

  @max_bytes 65_536
  @max_frontmatter_bytes 8_192
  @key ~r/^[-A-Za-z0-9_]+$/

  @spec parse(binary()) :: {:ok, map()} | {:error, atom()}
  def parse(markdown) when is_binary(markdown) do
    case extract(markdown) do
      {:ok, metadata, _body} -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_), do: {:error, :invalid_markdown}

  @spec extract(binary()) :: {:ok, map(), binary()} | {:error, atom()}
  def extract(markdown) when is_binary(markdown) do
    with :ok <- size_check(markdown),
         {:ok, frontmatter, body} <- split(markdown),
         :ok <- frontmatter_size_check(frontmatter),
         {:ok, metadata} <- parse_lines(frontmatter) do
      {:ok, metadata, body}
    end
  end

  def extract(_), do: {:error, :invalid_markdown}

  @spec valid?(binary()) :: boolean()
  def valid?(markdown), do: match?({:ok, _}, parse(markdown))

  defp size_check(markdown) do
    if byte_size(markdown) <= @max_bytes, do: :ok, else: {:error, :artifact_too_large}
  end

  defp frontmatter_size_check(frontmatter) do
    if byte_size(frontmatter) <= @max_frontmatter_bytes,
      do: :ok,
      else: {:error, :frontmatter_too_large}
  end

  defp split(<<"---\n", rest::binary>>) do
    case Regex.run(~r/\A(.*?)(?:\n|\r\n)---(?:\n|\r\n|\z)(.*)\z/s, rest, capture: :all_but_first) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, :frontmatter_missing_end}
    end
  end

  defp split(<<"---\r\n", rest::binary>>) do
    case Regex.run(~r/\A(.*?)(?:\n|\r\n)---(?:\n|\r\n|\z)(.*)\z/s, rest, capture: :all_but_first) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, :frontmatter_missing_end}
    end
  end

  defp split(_), do: {:error, :frontmatter_missing_start}

  defp parse_lines(frontmatter) do
    frontmatter
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, metadata} ->
      cond do
        String.trim(line) == "" ->
          {:cont, {:ok, metadata}}

        String.starts_with?(line, "#") ->
          {:cont, {:ok, metadata}}

        String.starts_with?(line, " ") or String.starts_with?(line, "\t") ->
          {:halt, {:error, :frontmatter_nested}}

        true ->
          case String.split(line, ":", parts: 2) do
            [key, value] ->
              key = String.trim(key)

              cond do
                not Regex.match?(@key, key) ->
                  {:halt, {:error, :frontmatter_key_invalid}}

                Map.has_key?(metadata, key) ->
                  {:halt, {:error, :frontmatter_duplicate_key}}

                true ->
                  case parse_value(value) do
                    {:ok, value} -> {:cont, {:ok, Map.put(metadata, key, value)}}
                    {:error, reason} -> {:halt, {:error, reason}}
                  end
              end

            _ ->
              {:halt, {:error, :frontmatter_line_invalid}}
          end
      end
    end)
  end

  defp parse_value(value) do
    value = String.trim(value)

    case value do
      <<"\"", rest::binary>> ->
        if String.ends_with?(rest, "\""),
          do: {:ok, String.slice(rest, 0..-2//1)},
          else: {:error, :frontmatter_unterminated_quote}

      <<"'", rest::binary>> ->
        if String.ends_with?(rest, "'"),
          do: {:ok, String.slice(rest, 0..-2//1)},
          else: {:error, :frontmatter_unterminated_quote}

      _ ->
        {:ok, value}
    end
  end
end
