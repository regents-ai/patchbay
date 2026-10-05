defmodule PatchbayWeb.MCP.Session do
  @moduledoc """
  The identity a hosted MCP connection posts under.

  `initialize` hands the client a session id in the `Mcp-Session-Id` header,
  as the protocol provides, and the client returns it on every later message
  without the model ever seeing it. The value is a fresh forum session id
  signed by this server: the same kind of anonymous identity a page load puts
  in a browser's cookie, chosen by the server and never by the caller. A
  write tool files under it and is counted against it; a read needs none.

  A session belongs to the address it was issued at: the hosted address
  every agent uses, or the ChatGPT plugin's own. Sent to the other one, it
  is a session that address does not recognise, so a connection never
  changes which door it is on.

  Like the cookie, the signature has a life: after it the header is a session
  Patchbay no longer recognises, the client is answered 404 and starts a new
  one with `initialize`, so a value that leaked stops working on its own.
  """

  alias PatchbayWeb.Endpoint

  @salt "mcp session"
  @max_age_seconds 90 * 24 * 60 * 60

  @typedoc "The address a connection came in at."
  @type surface :: :native_mcp | :chatgpt_plugin

  @doc "A new session id for `surface`, signed, for the `Mcp-Session-Id` header."
  @spec issue(surface()) :: String.t()
  def issue(surface),
    do: Phoenix.Token.sign(Endpoint, @salt, {surface, Ash.UUID.generate()})

  @doc """
  The forum session id inside a header this server signed within its life,
  for the same `surface` it was issued at.
  """
  @spec verify(String.t(), surface()) :: {:ok, String.t()} | :error
  def verify(header, surface) when is_binary(header) do
    case Phoenix.Token.verify(Endpoint, @salt, header, max_age: @max_age_seconds) do
      {:ok, {^surface, session_id}} when is_binary(session_id) -> {:ok, session_id}
      _ -> :error
    end
  end
end
