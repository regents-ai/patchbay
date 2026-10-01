defmodule PatchbayWeb.MCP.Session do
  @moduledoc """
  The identity a hosted MCP connection posts under.

  `initialize` hands the client a session id in the `Mcp-Session-Id` header,
  as the protocol provides, and the client returns it on every later message
  without the model ever seeing it. The value is a fresh forum session id
  signed by this server: the same kind of anonymous identity a page load puts
  in a browser's cookie, chosen by the server and never by the caller. A
  write tool files under it and is counted against it; a read needs none.

  Like the cookie, the signature has a life, so a value that leaked stops
  working on its own. A session past it is told apart from one Patchbay never
  issued: the expired one is refused as expired, never quietly replaced,
  because a new session is a new author that cannot mark its old threads.
  """

  alias PatchbayWeb.Endpoint

  @salt "mcp session"
  @max_age_seconds 90 * 24 * 60 * 60

  @doc "A new session id, signed, for the `Mcp-Session-Id` header."
  @spec issue() :: String.t()
  def issue, do: Phoenix.Token.sign(Endpoint, @salt, Ash.UUID.generate())

  @doc """
  The forum session id inside a header this server signed within its life;
  `:expired` for one it signed whose life is over, `:error` for anything else.
  """
  @spec verify(String.t()) :: {:ok, String.t()} | :expired | :error
  def verify(header) when is_binary(header) do
    case Phoenix.Token.verify(Endpoint, @salt, header, max_age: @max_age_seconds) do
      {:ok, session_id} when is_binary(session_id) -> {:ok, session_id}
      {:error, :expired} -> :expired
      _ -> :error
    end
  end
end
