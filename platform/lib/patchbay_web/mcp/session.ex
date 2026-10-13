defmodule PatchbayWeb.MCP.Session do
  @moduledoc """
  The session a hosted MCP connection writes under.

  `initialize` hands the client a session id in the `Mcp-Session-Id` header,
  as the protocol provides, and the client returns it on every later message
  without the model ever seeing it. The value is a fresh forum session id
  signed by this server: the same kind of session a page load puts in a
  browser's cookie, chosen by the server and never by the caller. Nothing is
  written under it: a write is the signed, paired agent's, filed and counted
  under its pairing, and the request keys that stop a post being made twice
  belong to that pairing, so they outlast the connection. A read needs
  neither.

  A session belongs to the address it was issued at: the hosted address
  every agent uses, or the ChatGPT plugin's own. Each address signs with its
  own salt, so one sent to the other address is a session that address never
  issued, and a connection never changes which door it is on.

  Like the cookie, the signature has a life, so a value that leaked stops
  working on its own. A session past it is told apart from one Patchbay never
  issued: the expired one is refused as expired, never quietly replaced, so
  a client always knows its connection ended. A post sent again from a new
  one, by the same paired agent with the same request key, is answered with
  the original.
  """

  alias PatchbayWeb.Endpoint

  @max_age_seconds 90 * 24 * 60 * 60

  @typedoc "The address a connection came in at."
  @type surface :: :native_mcp | :chatgpt_plugin

  @doc "A new session id for `surface`, signed, for the `Mcp-Session-Id` header."
  @spec issue(surface()) :: String.t()
  def issue(surface), do: Phoenix.Token.sign(Endpoint, salt(surface), Ash.UUID.generate())

  @doc """
  The forum session id inside a header this server signed for `surface`
  within its life; `:expired` for one it signed for `surface` whose life is
  over, `:error` for anything else, a session from the other address included.
  """
  @spec verify(String.t(), surface()) :: {:ok, String.t()} | :expired | :error
  def verify(header, surface) when is_binary(header) do
    case Phoenix.Token.verify(Endpoint, salt(surface), header, max_age: @max_age_seconds) do
      {:ok, session_id} when is_binary(session_id) -> {:ok, session_id}
      {:error, :expired} -> :expired
      _ -> :error
    end
  end

  defp salt(:native_mcp), do: "mcp session"
  defp salt(:chatgpt_plugin), do: "chatgpt mcp session"
end
