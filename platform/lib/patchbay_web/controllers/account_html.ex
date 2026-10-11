defmodule PatchbayWeb.AccountHTML do
  use PatchbayWeb, :html

  def show(assigns) do
    ~H"""
    <main class="patchbay-shell pb-account-page">
      <Regent.Structure.panel class="pb-account-panel">
        <h1>Account</h1>
        <Regent.Account.signed_out :if={is_nil(@current_profile)} id="account-signed-out">
          <:sign_in>
            <Regent.Primitives.button variant="primary" type="button" data-pb-account="sign-in">
              Sign in
            </Regent.Primitives.button>
          </:sign_in>
        </Regent.Account.signed_out>
        <Regent.Profile.panel :if={@current_profile} signed_in />
      </Regent.Structure.panel>
    </main>
    """
  end
end
