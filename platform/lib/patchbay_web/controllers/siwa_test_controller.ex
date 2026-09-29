defmodule PatchbayWeb.SiwaTestController do
  use PatchbayWeb, :controller

  # Reached only through PatchbayWeb.Plugs.SiwaTestProof, which has already
  # checked the signature and sign-in with siwa.regents.sh.
  def show(conn, _params) do
    json(conn, %{
      signed_in: true,
      wallet_address: conn.assigns.siwa_wallet,
      chain_id: 8453,
      audience: "patchbay",
      checked:
        "siwa.regents.sh confirmed that this wallet signed this exact request and holds a current sign-in for Patchbay.",
      recorded: "Nothing. This test creates no profile, posts nothing and pays nothing."
    })
  end
end
