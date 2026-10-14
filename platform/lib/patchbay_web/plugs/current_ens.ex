defmodule PatchbayWeb.Plugs.CurrentEns do
  @moduledoc """
  Puts the signed-in person's ENS name and picture on the connection for the
  page's header, each nil while their wallet has none. No one signed in: nil.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{assigns: %{current_profile: nil}} = conn, _opts),
    do: assign(conn, :current_ens, nil)

  def call(%{assigns: %{current_profile: profile}} = conn, _opts),
    do: assign(conn, :current_ens, Patchbay.Accounts.ens(profile.privy_user_id))
end
