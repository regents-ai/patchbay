defmodule Patchbay.Offers.Steps do
  @moduledoc """
  The transactions the offers page's buttons send, built here on the server
  (`RegentChain.Review.step/3`): letting the market take a purchase's USDC,
  the purchase itself with Patchbay's admission, and a claim of a wallet's
  credit.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Contract
  alias RegentChain.{Call, Review}

  @doc "Lets the market take exactly `amount` USDC base units from the sender."
  @spec approve(pos_integer()) :: Review.transaction()
  def approve(amount),
    do:
      Review.step(
        "approve",
        Offers.usdc(),
        Call.encode("approve(address,uint256)", [Offers.market(), amount])
      )

  @doc "Buys the slot an admission (`Patchbay.Offers.Admission.admit/6`) names."
  @spec buy(%{purchase: Offers.Admission.purchase(), permit: String.t()}) :: Review.transaction()
  def buy(%{purchase: purchase, permit: "0x" <> permit}) do
    order =
      {purchase.placement_id, purchase.slot, bytes(purchase.campaign_id), purchase.amount,
       purchase.expected_nonce, purchase.deadline}

    Review.step(
      "buy",
      Offers.market(),
      hex(Contract.buy(order, Base.decode16!(permit, case: :lower)))
    )
  end

  @doc "Sends all of the sender's credit in the market to `wallet`."
  @spec claim(String.t()) :: Review.transaction()
  def claim(wallet), do: Review.step("claim", Offers.market(), hex(Contract.claim(wallet)))

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp hex(tx_data), do: Ethers.Utils.hex_encode(tx_data.data)
end
