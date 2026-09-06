defmodule PatchbayWeb.SharedProfileHTML do
  use PatchbayWeb, :html

  def show(assigns) do
    ~H"""
    <main class="pb-main" style="max-width: 42rem; margin: 2rem auto; padding: 1rem;">
      <Regent.Profile.panel />
    </main>
    """
  end
end
