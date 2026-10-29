defmodule Patchbay.AddressText do
  @moduledoc """
  Words that carry full `0x` addresses, cut into pieces so a page can draw each
  address with `Regent.Primitives.address` (it opens and copies the full
  address) and the words around it as they are. Markdown twins keep the plain
  text; only the HTML page draws the pieces.
  """

  @address ~r/(?<![0-9a-zA-Z])0x[0-9a-fA-F]{40}(?![0-9a-zA-Z])/
  # Private-use characters around an address in a markdown document, so the
  # rendered HTML can be cut where each address stood and nowhere else.
  @open "\u{E000}"
  @close "\u{E001}"
  @marked ~r/\x{E000}(0x[0-9a-fA-F]{40})\x{E001}/u

  @typedoc "Words as they are, or an address to draw."
  @type piece :: String.t() | {:address, String.t()}

  @typedoc "Rendered HTML as it is, or an address to draw."
  @type html_piece :: {:html, String.t()} | {:address, String.t()}

  @doc """
  Plain words with each full address cut out.

      iex> Patchbay.AddressText.split("to 0x1234567890abcdef1234567890abcdef12345678, then")
      ["to ", {:address, "0x1234567890abcdef1234567890abcdef12345678"}, ", then"]
  """
  @spec split(String.t()) :: [piece()]
  def split(text) when is_binary(text) do
    @address
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn part -> if Regex.match?(@address, part), do: {:address, part}, else: part end)
  end

  @doc """
  A markdown document rendered to HTML, with each full address in its words or
  in an inline code span cut out, rendered with the options it was parsed with.
  An address stays as written in a code block, which is copied whole, and in a
  picture's words, a heading or a link's words, which the page puts in
  attributes or inside a link where the address piece cannot go.
  """
  @spec html(MDEx.Document.t()) :: [html_piece()]
  def html(%MDEx.Document{} = document) do
    document
    |> mark()
    |> MDEx.to_html!()
    |> then(&Regex.split(@marked, &1, include_captures: true, trim: true))
    |> Enum.map(fn piece ->
      case Regex.run(@marked, piece, capture: :all_but_first) do
        [address] -> {:address, address}
        nil -> {:html, piece}
      end
    end)
  end

  @left_as_written [MDEx.Image, MDEx.Link, MDEx.Heading]

  defp mark(%kind{} = node) when kind in @left_as_written, do: node

  defp mark(%MDEx.Text{literal: literal} = text),
    do: %{text | literal: Regex.replace(@address, literal, @open <> "\\0" <> @close)}

  defp mark(%MDEx.Code{literal: literal} = code) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, literal),
      do: %MDEx.Text{literal: @open <> literal <> @close},
      else: code
  end

  defp mark(%{nodes: nodes} = node) when is_list(nodes),
    do: %{node | nodes: Enum.map(nodes, &mark/1)}

  defp mark(node), do: node
end
