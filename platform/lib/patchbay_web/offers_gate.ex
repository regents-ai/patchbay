defmodule PatchbayWeb.OffersGate do
  @moduledoc """
  The gate on agent offers' addresses (`Patchbay.Offers.enabled?/0`): while no
  market is set, as in production, a request answers the site's own 404 and a
  connected page goes to the home page, as `PatchbayWeb.Showcase` gates the
  motion lab.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Patchbay.Offers.enabled?() or raise PatchbayWeb.Forum.NotFoundError
    conn
  end

  def on_mount(:default, _params, _session, socket) do
    if Patchbay.Offers.enabled?(),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
