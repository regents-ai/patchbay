defmodule PatchbayWeb.OAuthController do
  @moduledoc """
  Boruta protocol routes and consent under the verified browser session and CSRF.

  The connected-apps page is the shared library's, except for a browser that
  is signed out and asks for a web page: it gets Patchbay's own page saying to
  sign in, with the site's Sign in button. Any other caller signed out keeps
  the library's JSON answer.

  Connected-app sign-in lives only at the open address. At patchbay.help the
  register, token and revoke addresses answer a 404 in OAuth's error shape
  (RFC 6749, section 5.2) naming the same address there, and use nothing the
  request sent: an app that reads threads at patchbay.help's `/mcp` and then
  asks here for a token learns where to ask.
  """
  use PatchbayWeb, :controller

  alias PatchbayWeb.SiteEdition

  plug :rate_limit when action in [:register, :token, :revoke]
  plug :open_address_only when action in [:register, :token, :revoke]

  for action <- [:resource_metadata, :server_metadata, :register, :token, :revoke] do
    def unquote(action)(conn, _params), do: RegentOAuth.Protocol.call(conn, unquote(action))
  end

  for action <- [:authorize, :approve, :revoke_connection] do
    def unquote(action)(conn, _params), do: apply(RegentOAuth.Consent, unquote(action), [conn])
  end

  def connections(%{assigns: %{current_profile: nil}} = conn, _params) do
    if asks_for_web_page?(conn) do
      conn
      |> put_status(:unauthorized)
      |> put_resp_header("cache-control", "no-store")
      |> render(:sign_in, PatchbayWeb.PublicDocuments.page("/oauth/connections"))
    else
      RegentOAuth.Consent.connections(conn)
    end
  end

  def connections(conn, _params), do: RegentOAuth.Consent.connections(conn)

  defp asks_for_web_page?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp rate_limit(conn, _opts) do
    {address, _source} = PatchbayWeb.ClientAddress.key(conn)
    action = action_name(conn)
    limit = if action == :register, do: 30, else: 120

    case PatchbayWeb.ReadLimit.admit({:oauth, action, address}, limit, 60) do
      {:ok, _} ->
        conn

      {:error, :rate_limited, _} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> RegentOAuth.Protocol.json(429, %{error: "rate_limited"})
        |> halt()
    end
  end

  defp open_address_only(%{assigns: %{site_edition: :open}} = conn, _opts), do: conn

  defp open_address_only(%{assigns: %{site_edition: :main}} = conn, _opts) do
    there = "#{SiteEdition.url(:open)}/oauth/#{action_name(conn)}"

    conn
    |> put_status(:not_found)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> json(%{
      error: "invalid_request",
      error_description: "Connected-app sign-in is not at this address. Use #{there}"
    })
    |> halt()
  end
end
