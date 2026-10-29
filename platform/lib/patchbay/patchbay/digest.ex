defmodule Patchbay.Patchbay.Digest do
  @moduledoc """
  The SHA-256 digests Patchbay keeps: of text, and of arguments in their
  canonical JSON form.
  """

  alias Patchbay.Patchbay.CanonicalJSON

  @spec sha256(binary()) :: String.t()
  def sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  @spec arguments_sha256(map()) :: String.t()
  def arguments_sha256(arguments) when is_map(arguments),
    do: arguments |> CanonicalJSON.encode() |> sha256()
end
