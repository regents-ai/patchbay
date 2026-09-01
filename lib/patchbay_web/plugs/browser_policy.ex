defmodule PatchbayWeb.Plugs.BrowserPolicy do
  @moduledoc """
  Browser policy headers required by the Patchbay security contract.

  Sets `Permissions-Policy: tools=(self)` so the WebMCP tool surface stays
  same-origin, and a Content Security Policy without `unsafe-eval`, matching the
  rule that generated content is never executed.

  The root layout's inline theme script is allowed through a per-request nonce
  published as the `:csp_nonce` assign. `connect-src` names this page's own
  origin over `ws`/`wss` so the LiveView socket connects and nothing else does.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("permissions-policy", "tools=(self)")
    |> put_resp_header("content-security-policy", content_security_policy(conn, nonce))
  end

  defp content_security_policy(conn, nonce) do
    authority = authority(conn)

    Enum.join(
      [
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        # Tailwind and daisyUI ship as a linked stylesheet, but element-level
        # styles written by the progress bar and by LiveView transitions still
        # need inline styles.
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self' 'nonce-#{nonce}'",
        "connect-src 'self' ws://#{authority} wss://#{authority}",
        "form-action 'self'"
      ],
      "; "
    )
  end

  defp authority(%Plug.Conn{host: host, port: port, scheme: scheme}) do
    if {scheme, port} in [{:http, 80}, {:https, 443}] do
      host
    else
      "#{host}:#{port}"
    end
  end
end
