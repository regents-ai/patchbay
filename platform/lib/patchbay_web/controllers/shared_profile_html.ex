defmodule PatchbayWeb.SharedProfileHTML do
  use PatchbayWeb, :html

  def show(assigns) do
    ~H"""
    <main class="patchbay-shell pb-profile-page">
      <Regent.Structure.panel class="pb-profile-panel">
        <Regent.Profile.panel signed_in={not is_nil(@current_profile)} />
      </Regent.Structure.panel>
    </main>
    """
  end
end
