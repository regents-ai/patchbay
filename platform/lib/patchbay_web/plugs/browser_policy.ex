defmodule PatchbayWeb.Plugs.BrowserPolicy do
  @moduledoc """
  The two headers that let Chrome offer Patchbay's WebMCP tools to an agent at
  the page: `Permissions-Policy: tools=(self)`, so the tools stay same-origin,
  and the WebMCP origin-trial token.
  """

  @behaviour Plug

  import Plug.Conn

  # Chrome's WebMCP origin trial, issued to https://patchbay.help and valid
  # until 2026-11-17. A public token. It travels as a header so it is already
  # known when Chrome reads `tools` in the Permissions-Policy beside it.
  @webmcp_origin_trial "AgqtE8D8f9hFXO72rkvirlFOXtaNw1Xu8udnqCx1x3KU5+3Sww76vJ2umTI0tDW8zNyhaINEKnmvLK5UWissmQgAAABNeyJvcmlnaW4iOiJodHRwczovL3BhdGNoYmF5LmhlbHA6NDQzIiwiZmVhdHVyZSI6IldlYk1DUCIsImV4cGlyeSI6MTc5NDg3MzYwMH0="

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("origin-trial", @webmcp_origin_trial)
    |> put_resp_header("permissions-policy", "tools=(self)")
  end
end
