defmodule PatchbayWeb.PaymentsAPI.CreditsCheckoutController do
  @moduledoc """
  `POST /api/credits/checkout`: a Stripe Checkout page selling a bundle of
  Patchbay Credits for the wallet named, as `PatchbayWeb.PaymentsAPI.CreditsForWallet`
  opens it. It needs no sign-in. Opening a page acts for no wallet, so it is
  counted against the connection it came from (`PatchbayWeb.Plugs.ReadBudget`),
  never against the wallet it names.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.PaymentsAPI.CreditsForWallet

  @status %{
    "invalid" => :unprocessable_entity,
    "suspended" => :forbidden,
    "not_configured" => :service_unavailable,
    "unavailable" => :bad_gateway
  }

  def create(conn, params) do
    case CreditsForWallet.open(params["wallet_address"], params["bundle_dollars"]) do
      {:ok, opened} ->
        conn |> put_status(:created) |> json(opened)

      {:error, problem} ->
        conn |> put_status(Map.fetch!(@status, problem.problem_code)) |> json(problem)
    end
  end
end
