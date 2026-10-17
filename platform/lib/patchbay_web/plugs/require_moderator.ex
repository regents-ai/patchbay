defmodule PatchbayWeb.Plugs.RequireModerator do
  @moduledoc """
  The door to the moderation page.

  Only a signed-in profile whose verified wallet is in this deployment's
  moderator allowlist passes. Anything else gets the site's ordinary
  not-found page, as an unknown address does: the door is private, so its
  absence is the answer.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Patchbay.Checks.Moderator.moderator?(conn.assigns[:current_profile]) do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: PatchbayWeb.Router
    end
  end
end
