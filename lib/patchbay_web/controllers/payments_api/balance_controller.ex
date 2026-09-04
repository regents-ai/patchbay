defmodule PatchbayWeb.PaymentsAPI.BalanceController do
  @moduledoc """
  What the signed-in profile holds in USDC, read from its own wallet on Base.

  Tips settle straight into the recipient's wallet, so there is nothing to
  withdraw from Patchbay: the balance shown is the wallet's own, and the
  address shown is the one Privy verified when that profile signed in. The
  wallet read is always the session's; a caller cannot name another.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Payments.Balance
  alias Patchbay.Payments.USDC

  def show(conn, _params) do
    profile = conn.assigns.current_profile

    case Balance.available_usdc_atomic(profile.wallet_address) do
      {:ok, atomic} ->
        json(conn, %{
          profile_id: profile.public_id,
          network: USDC.network(),
          asset: "USDC",
          available_usdc: USDC.format(atomic),
          verified_payout_address: profile.wallet_address,
          funding: %{
            network: "Base mainnet",
            chain_id: 8453,
            asset: "USDC",
            asset_contract: USDC.asset(),
            wallet_address: profile.wallet_address,
            warning: "Send native USDC on Base only. Never share a private key or recovery phrase."
          }
        })

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "Reading balances is not set up on this Patchbay.",
          problem_code: "not_configured",
          next_action: "Use the free Patchbay tools. Payments are not enabled on this deployment.",
          payment_help_url: url(~p"/agent-setup") <> "#x402"
        })

      {:error, :rpc_failed} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "The Base network could not be read just now. Try again."})
    end
  end
end
