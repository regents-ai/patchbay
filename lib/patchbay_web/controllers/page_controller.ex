defmodule PatchbayWeb.PageController do
  use PatchbayWeb, :controller

  alias Patchbay.Patchbay.Fixtures

  # The deployment serves exactly one public room, so the bare domain goes
  # straight to it rather than to a landing page.
  def home(conn, _params) do
    redirect(conn, to: ~p"/webmcp/rooms/#{Fixtures.slug()}")
  end
end
