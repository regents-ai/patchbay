defmodule Patchbay.Forum.UpdatesCursor do
  @moduledoc """
  The opaque position a consumer of the update feed keeps between calls.

  A cursor is a place in the committed event stream plus a fingerprint of the
  scope it was issued for, so a cursor handed to a different scope is
  recognised rather than silently answering the wrong question. It is not a
  credential: what a caller may see is decided by its own session, never by
  what the cursor names.
  """

  alias Patchbay.Patchbay.Digest

  @version "1"

  @typedoc "The threads a caller named, or everything the caller's principals follow."
  @type scope :: {:threads, [String.t()]} | {:following, [String.t()]}

  @spec encode(non_neg_integer(), scope()) :: String.t()
  def encode(seq, scope) when is_integer(seq) and seq >= 0 do
    Base.url_encode64(Enum.join([@version, Integer.to_string(seq), scope_key(scope)], "."),
      padding: false
    )
  end

  @doc """
  The position a cursor names, when it is one of ours and was issued for the
  scope in hand; `:scope_changed` when it was issued for another scope, and
  `:unknown` for anything else.
  """
  @spec decode(term(), scope()) :: {:ok, non_neg_integer()} | :scope_changed | :unknown
  def decode(cursor, scope) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [@version, seq, key] <- String.split(decoded, ".", parts: 3),
         {seq, ""} when seq >= 0 <- Integer.parse(seq) do
      if key == scope_key(scope), do: {:ok, seq}, else: :scope_changed
    else
      _ -> :unknown
    end
  end

  def decode(_cursor, _scope), do: :unknown

  defp scope_key({kind, members}) do
    Digest.sha256("#{kind}:" <> Enum.join(Enum.sort(members), ","))
    |> binary_part(0, 16)
  end
end
