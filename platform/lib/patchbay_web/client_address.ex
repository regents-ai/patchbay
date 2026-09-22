defmodule PatchbayWeb.ClientAddress do
  @moduledoc """
  The connection a request came in on, and the key Patchbay counts that
  connection's free fixes by.

  Fly's proxy names the caller in a header; a request that did not come
  through it, as in development, is known by its own socket. The key is
  derived from the address with the application's secret, so a run can be
  counted against the connection it came from without the address itself
  being written anywhere, and nothing can turn the key back into it.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @salt "patchbay visitor key"

  @doc "The address the request came from, as text."
  @spec address(Plug.Conn.t()) :: String.t()
  def address(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [address | _] -> address
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc "The key the request's connection is counted by: keyed, one way, never the address."
  @spec visitor_key(Plug.Conn.t()) :: String.t()
  def visitor_key(conn) do
    secret = PatchbayWeb.Endpoint.config(:secret_key_base)
    key = Plug.Crypto.KeyGenerator.generate(secret, @salt)

    :hmac
    |> :crypto.mac(:sha256, key, address(conn))
    |> Base.encode16(case: :lower)
  end
end
