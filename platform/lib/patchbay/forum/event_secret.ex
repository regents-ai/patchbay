defmodule Patchbay.Forum.EventSecret do
  @moduledoc """
  Keeps an events subscription's signing secret encrypted at rest, under the
  endpoint's `secret_key_base`. Only the delivery worker opens it, to sign a
  webhook; it is never returned or logged.
  """

  @salt "mcp event signing secret"

  @spec seal(String.t()) :: String.t()
  def seal(secret) when is_binary(secret),
    do: Plug.Crypto.encrypt(key_base(), @salt, secret)

  @spec open(String.t()) :: String.t()
  def open(ciphertext) when is_binary(ciphertext) do
    {:ok, secret} = Plug.Crypto.decrypt(key_base(), @salt, ciphertext, max_age: :infinity)
    secret
  end

  defp key_base, do: PatchbayWeb.Endpoint.config(:secret_key_base)
end
