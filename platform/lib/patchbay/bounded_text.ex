defmodule Patchbay.BoundedText do
  @moduledoc """
  One rule for text that came from a browser or another site and is about to
  be shown or kept.

  Arguments, handler responses, notes, recorded maps and the words a site
  writes about its tools are all as long as whoever wrote them chose to make
  them, so every one of them is cut to a budget before it reaches a page or a
  stored record: a byte budget (`take/2`) or, for text a reader reads, a
  character budget cut between words with "…" at the end (`cut/2`).
  """

  @doc """
  The text cut to at most `limit` bytes, paired with whether cutting shortened it.

  A byte budget can land inside a multi-byte character, so trailing bytes are
  dropped until what is left is printable text again. Text already inside the
  budget is handed back untouched.
  """
  @spec take(binary(), pos_integer()) :: {binary(), boolean()}
  def take(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if byte_size(text) > limit,
      do: {trim_to_text(binary_part(text, 0, limit)), true},
      else: {text, false}
  end

  defp trim_to_text(chunk) do
    if String.valid?(chunk),
      do: chunk,
      else: trim_to_text(binary_part(chunk, 0, byte_size(chunk) - 1))
  end

  @doc """
  The text whole when it has at most `limit` characters; otherwise cut
  between words to at most `limit` characters with "…" at the end, so a
  reader can tell it was cut. The cut drops the spaces and the commas,
  colons, semicolons and full stops before the "…"; only a single word
  longer than `limit` is cut inside.
  """
  @spec cut(String.t(), pos_integer()) :: String.t()
  def cut(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      text
    else
      kept = String.slice(text, 0, limit - 1)

      # The last word is whole only when a space follows it.
      kept =
        case {String.at(text, limit - 1) =~ ~r/\s/u, String.split(kept, ~r/\s+(?=\S*\z)/u)} do
          {true, _words} -> kept
          {false, [whole]} -> whole
          {false, [head, _partial_word]} -> head
        end

      String.replace(kept, ~r/[\s,;:.]+\z/u, "") <> "…"
    end
  end
end
