defmodule PatchbayWeb.Plugs.ProfileOwner do
  @moduledoc """
  Puts the profile's owner on a profile API request (`RegentIdentity.HTTP`): the
  person signed in on this browser, read from the session cookie as every page
  reads it (`PatchbayWeb.Plugs.CurrentProfile`). A request that changes
  something carries the session's forms token in x-csrf-token, as the site's
  pages send it; one without it counts as signed out, so another site's page can
  never act with the person's cookie. A signed-out request, or one whose sign-in
  has ended, gets no owner, and the profile API refuses it with
  `authentication_required`.
  """

  @behaviour Plug

  import Plug.Conn

  alias PatchbayWeb.Plugs.CurrentProfile

  @forms_token Plug.CSRFProtection.init(with: :clear_session)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn =
      conn
      |> fetch_session()
      |> Plug.CSRFProtection.call(@forms_token)
      |> CurrentProfile.call([])

    case conn.assigns.current_profile do
      %{privy_user_id: privy_user_id} ->
        RegentIdentity.HTTP.put_owner(conn, %RegentIdentity.Owner{
          app_id: Patchbay.Identity.Privy.app_id(),
          privy_user_id: privy_user_id
        })

      nil ->
        conn
    end
  end
end
