defmodule PatchbayWeb.CurrentProfile do
  @moduledoc """
  Gives every live view the same `@current_profile` a plain page gets.

  A live view reads the session it was mounted with rather than the connection,
  so the profile is looked up here from the same signed key the plug reads.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PatchbayWeb.Plugs.CurrentProfile

  def on_mount(:default, _params, session, socket) do
    {:cont, assign(socket, :current_profile, CurrentProfile.signed_in_profile(session))}
  end
end
