defmodule PatchbayWeb.ClientAddress do
  @moduledoc """
  The connection a request came in on, and the key Patchbay counts that
  connection's free fixes by.

  Fly's proxy names the caller in a header; a request that did not come
  through it, as in development, is known by its own socket. The key is
  derived from the address with the application's secret, so a run can be
  counted against the connection it came from without the address itself
  being written anywhere, and nothing can turn the key back into it.

  An IPv6 connection is counted by its first 64 bits: one home or one
  server is handed a whole block of that size and can pick any address in
  it, so a key per address would be a free fix per address.
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
    key = Plug.Crypto.KeyGenerator.generate(secret, @salt, cache: Plug.Crypto.Keys)

    :hmac
    |> :crypto.mac(:sha256, key, counted(address(conn)))
    |> Base.encode16(case: :lower)
  end

  # The part of the address a connection is counted by: all of an IPv4
  # address, the network half of an IPv6 one.
  defp counted(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, low}} ->
        to_string(:inet.ntoa({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}))

      {:ok, {a, b, c, d, _e, _f, _g, _h}} ->
        to_string(:inet.ntoa({a, b, c, d, 0, 0, 0, 0})) <> "/64"

      {:ok, ipv4} ->
        to_string(:inet.ntoa(ipv4))

      {:error, :einval} ->
        address
    end
  end
end
