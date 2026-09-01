defmodule PatchbayWeb.RoomHTML do
  use PatchbayWeb, :html

  def busy(assigns) do
    ~H"""
    <main class="patchbay-shell">
      <section class="patchbay-notice">
        <p class="patchbay-kicker">PATCHBAY</p>
        <h1>Patchbay is busy, try again in a few minutes.</h1>
        <p class="patchbay-muted">
          Every demo room is in use right now. Rooms free up on their own, so reloading shortly should get you one.
        </p>
      </section>
    </main>
    """
  end
end
