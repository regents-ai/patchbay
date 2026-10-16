defmodule PatchbayWeb.ForumAPI.OfferBidController do
  @moduledoc """
  Where a paired agent bids on Agent Offer slots for its person
  (`PatchbayWeb.ForumAPI.OfferBidding`). Nothing a caller sends names who
  bids: every action is the paired person's own, and a bid's Credits are
  held as the agent's spend, inside the limits the person set for it at
  regents.sh/account.

  Two reads show the person's own Offers as the Active and History tabs do
  (`PatchbayWeb.ForumAPI.MyOffers`); they hold, pay and change nothing.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Credits
  alias Patchbay.Identity
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.MyOffers
  alias PatchbayWeb.ForumAPI.OfferBidding

  def options(conn, params), do: answer(conn, :ok, OfferBidding.options(person(conn), params))

  def create(conn, params),
    do: answer(conn, :created, OfferBidding.bid(person(conn), spender(conn), params))

  def fit(conn, params), do: answer(conn, :created, OfferBidding.ask_fit(person(conn), params))
  def save(conn, params), do: answer(conn, :created, OfferBidding.save(person(conn), params))

  def reword(conn, params),
    do: answer(conn, :created, OfferBidding.reword(person(conn), params))

  def active(conn, params),
    do: answer(conn, :ok, MyOffers.active(conn.assigns.agent_actor, params))

  def history(conn, params),
    do: answer(conn, :ok, MyOffers.history(conn.assigns.agent_actor, params))

  # The paired person, whom the pairing check already found active here.
  defp person(conn), do: Identity.get_profile!(conn.assigns.agent_actor.beneficiary_profile_id)

  defp spender(conn) do
    actor = conn.assigns.agent_actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      Credits.site(),
      actor.pairing_id
    )
  end

  defp answer(conn, status, {:ok, payload}), do: conn |> put_status(status) |> json(payload)

  defp answer(conn, _status, {:error, :invalid_cursor}),
    do: conn |> put_status(:unprocessable_entity) |> json(MyOffers.invalid_cursor())

  defp answer(conn, _status, {:error, {:invalid, messages}}),
    do: conn |> put_status(:unprocessable_entity) |> json(ApiError.invalid(messages))

  defp answer(conn, _status, {:error, {:not_enough_credits, words}}) do
    refuse(
      conn,
      :unprocessable_entity,
      "not_enough_credits",
      words,
      "Nothing was held. The person can buy Credits from Buy Credits at the top of any Patchbay page."
    )
  end

  defp answer(conn, _status, {:error, {:agent_spending, words}}) do
    refuse(
      conn,
      :forbidden,
      "agent_spending_refused",
      words,
      "Nothing was held. Your person sets what you may spend at https://regents.sh/account; account_balances shows it."
    )
  end

  defp answer(conn, _status, {:error, {:refused, words}}) do
    refuse(
      conn,
      :unprocessable_entity,
      "bid_refused",
      words,
      "Nothing was held. Read get_offer_bid_options again and bid with what it gives."
    )
  end

  defp answer(conn, _status, {:error, {:not_saved, words}}) do
    refuse(
      conn,
      :unprocessable_entity,
      "not_saved",
      words,
      "Change what the message names, then send it again."
    )
  end

  defp answer(conn, _status, {:error, {:unavailable, words}}),
    do: refuse(conn, :service_unavailable, "unavailable", words, "Try again in a moment.")

  defp refuse(conn, status, code, words, hint),
    do: conn |> put_status(status) |> json(ApiError.body(code, words, hint))
end
