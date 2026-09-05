defmodule Patchbay.BoundedText do
  @moduledoc """
  One rule for text that came from a browser and is about to be shown or kept.

  Arguments, handler responses, notes, and recorded maps are all as long as
  whoever sent them chose to make them, so every one of them is cut to a byte
  budget before it reaches a page or a stored record.
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
end
