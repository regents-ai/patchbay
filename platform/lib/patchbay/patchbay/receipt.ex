defmodule Patchbay.Patchbay.Receipt do
  @moduledoc """
  The unguessable stub Patchbay hands back with every tool call it ran.

  An agent can claim anything about a call it says it made. A receipt is the one
  thing it cannot invent: 16 random bytes minted when the call is recorded, kept
  on the invocation row, returned to the agent in the result, and printed on the
  server's own log line for that call. Quoting one back is how a report gets tied
  to a call Patchbay actually ran.
  """

  @bytes 16
  @shape ~r/\A[A-Za-z0-9_-]{22}\z/

  @doc "A fresh receipt: 16 random bytes as url-safe base64 without padding."
  @spec generate() :: String.t()
  def generate, do: @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether a value could be a receipt at all. Anything else names no call."
  @spec shape?(term()) :: boolean()
  def shape?(value) when is_binary(value), do: Regex.match?(@shape, value)
  def shape?(_value), do: false
end
