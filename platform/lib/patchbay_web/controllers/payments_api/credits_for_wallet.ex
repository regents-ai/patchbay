defmodule PatchbayWeb.PaymentsAPI.CreditsForWallet do
  @moduledoc """
  Opens a Stripe Checkout page, card or Link, selling one bundle of Patchbay
  Credits for a wallet the buyer names, with no sign-in: anyone may add
  credits to any wallet, and nobody can take them out. The hosted MCP tool
  `buy_credits` and `POST /api/credits/checkout` both answer from here.

  The page names the wallet and the credits, so the buyer sees what they buy
  and for whom before paying. Opening it writes nothing to the ledger: the
  credits are written only when Stripe's signed event says the payment was
  taken (`PatchbayWeb.StripeWebhookController`), on the balance the wallet
  spends then, which is its person's once it is paired. A page left unpaid
  adds nothing.
  """

  use PatchbayWeb, :verified_routes

  require Logger

  alias Patchbay.Identity
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.AuthorJSON

  @wallet_shape "wallet_address: must be a Base wallet address, 0x followed by 40 hex characters"

  @doc """
  The checkout page for `dollars` of credits for `wallet`, with what it buys
  and for whom, or the problem with the request.
  """
  @spec open(term(), term()) :: {:ok, map()} | {:error, map()}
  def open(wallet, dollars) do
    with :ok <- on_sale(),
         {:ok, wallet} <- wallet_address(wallet),
         {:ok, dollars} <- bundle(dollars),
         {:ok, recipient} <- recipient(wallet),
         {:ok, checkout_url} <- checkout(recipient, dollars) do
      {:ok,
       %{
         checkout_url: checkout_url,
         credits: Credits.written(Credits.atomic_from_cents(dollars * 100)),
         price_usd: "#{dollars}.00",
         recipient: %{
           wallet_address: wallet,
           profile_url: url(~p"/agents/#{recipient.public_id}"),
           shares_with: shares_with(recipient)
         },
         next_action:
           "Open checkout_url and pay by card or Link. The credits are added to this wallet's " <>
             "Patchbay Credits once Stripe confirms the payment, usually within a minute; a " <>
             "checkout left unpaid adds nothing. The page expires after a day."
       }}
    end
  end

  defp on_sale do
    if Patchbay.Stripe.configured?(),
      do: :ok,
      else:
        {:error,
         %{problem_code: "not_configured", error: "Patchbay Credits are not on sale here."}}
  end

  defp wallet_address(wallet) when is_binary(wallet) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, wallet),
      do: {:ok, String.downcase(wallet)},
      else: invalid(@wallet_shape)
  end

  defp wallet_address(_wallet), do: invalid(@wallet_shape)

  defp bundle(dollars) when is_integer(dollars) do
    if Credits.bundle?(dollars), do: {:ok, dollars}, else: bundle(nil)
  end

  defp bundle(_dollars) do
    invalid(
      "bundle_dollars: one of #{Enum.join(Credits.bundles(), ", ")}, " <>
        "each buying that many Patchbay Credits"
    )
  end

  defp invalid(message), do: {:error, %{problem_code: "invalid", errors: [message]}}

  # The wallet's profile, made the first time anyone names it, as every agent
  # door does; a suspended one is sold nothing.
  defp recipient(wallet) do
    case Identity.upsert_from_wallet(%{wallet_address: wallet}) do
      {:ok, %{status: :active} = profile} ->
        {:ok, profile}

      {:ok, _suspended} ->
        {:error,
         %{problem_code: "suspended", error: "That wallet's profile is suspended on Patchbay."}}

      {:error, _failure} ->
        invalid(@wallet_shape)
    end
  end

  defp checkout(recipient, dollars) do
    product = %{
      name: "#{dollars} Patchbay Credits for wallet #{short(recipient.wallet_address)}",
      description:
        "Added to the Patchbay Credits of wallet #{recipient.wallet_address}" <>
          "#{shared(recipient)}. Credits pay for fixes and priority reports on " <>
          "patchbay.help and cannot be withdrawn."
    }

    urls = %{
      success: url(~p"/agents/#{recipient.public_id}?credits=bought"),
      cancel: url(~p"/agents/#{recipient.public_id}?credits=cancelled")
    }

    case Patchbay.Stripe.create_checkout(recipient.id, dollars, product, urls) do
      {:ok, checkout_url} ->
        {:ok, checkout_url}

      {:error, reason} ->
        Logger.error("stripe checkout for a wallet not opened: #{inspect(reason)}")

        {:error,
         %{
           problem_code: "unavailable",
           error: "The payment page could not be opened just now. Nothing was charged."
         }}
    end
  end

  defp shares_with(%{paired_person_id: nil}), do: nil

  defp shares_with(recipient),
    do: recipient.paired_person_id |> Identity.get_profile!() |> AuthorJSON.author()

  defp shared(%{paired_person_id: nil}), do: ""

  defp shared(_recipient),
    do: ", which it shares with the person it is paired with"

  defp short("0x" <> hex), do: "0x" <> String.slice(hex, 0, 4) <> "…" <> String.slice(hex, -4, 4)
end
