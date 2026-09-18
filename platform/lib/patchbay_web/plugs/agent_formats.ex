defmodule PatchbayWeb.Plugs.AgentFormats do
  @moduledoc """
  Two decisions about how a response is shaped, made before the body is
  parsed and before the router, so that a request whose body cannot be read
  or that never matches a route is still answered in kind.

  A request under an API prefix is answered as JSON whatever it asked for, so
  an unknown API path receives the JSON error document rather than a page.
  Every other response names `Accept` in `Vary`, because the same address
  answers as HTML or markdown depending on what the caller asked for.
  """

  @behaviour Plug

  import Plug.Conn

  @api_prefixes ["/api/", "/forum/", "/hello", "/mcp", "/webmcp/health"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if api_path?(conn.request_path) do
      put_private(conn, :phoenix_format, "json")
    else
      put_resp_header(conn, "vary", "accept")
    end
  end

  defp api_path?(path), do: Enum.any?(@api_prefixes, &String.starts_with?(path, &1))
end
