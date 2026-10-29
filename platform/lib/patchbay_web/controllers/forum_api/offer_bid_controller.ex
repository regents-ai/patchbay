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
  alias PatchbayWeb.Plugs.PairedAgent

  def options(conn, params), do: send_answer(conn, get_offer_bid_options(agent(conn), params))

  def create(conn, params),
    do: send_answer(conn, answer(:created, OfferBidding.bid(person(conn), spender(conn), params)))

  def fit(conn, params), do: send_answer(conn, ask_offer_fit(agent(conn), params))
  def save(conn, params), do: send_answer(conn, save_agent_offer(agent(conn), params))
  def reword(conn, params), do: send_answer(conn, reword_agent_offer(agent(conn), params))

  def active(conn, params),
    do: send_answer(conn, answer(:ok, MyOffers.active(agent(conn), params)))

  def history(conn, params),
    do: send_answer(conn, answer(:ok, MyOffers.history(agent(conn), params)))

  @doc """
  One slot as `actor`'s person would bid on it, as a status and a body:
  `POST /forum/offer-bid-options` and the `get_offer_bid_options` tool.
  Holds and changes nothing.
  """
  @spec get_offer_bid_options(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def get_offer_bid_options(actor, params),
    do: answer(:ok, OfferBidding.options(person(actor), params))

  @doc "Asks whether a wording fits a site, as `POST /forum/offer-fit-checks` does. Free."
  @spec ask_offer_fit(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def ask_offer_fit(actor, params),
    do: answer(:created, OfferBidding.ask_fit(person(actor), params))

  @doc "Saves a new Offer for screening, as `POST /forum/my-offers` does. Free."
  @spec save_agent_offer(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def save_agent_offer(actor, params),
    do: answer(:created, OfferBidding.save(person(actor), params))

  @doc "Saves new wording for an Offer, as `POST /forum/my-offers/{creative_id}/versions` does. Free."
  @spec reword_agent_offer(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def reword_agent_offer(actor, params),
    do: answer(:created, OfferBidding.reword(person(actor), params))

  defp agent(conn), do: conn.assigns.agent_actor

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  # The paired person, whom the pairing check already found active here.
  defp person(%Patchbay.Agents.Actor{} = actor),
    do: Identity.get_profile!(actor.beneficiary_profile_id)

  defp person(conn), do: person(agent(conn))

  defp spender(conn) do
    actor = conn.assigns.agent_actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      Credits.site(),
      actor.pairing_id
    )
  end

  defp answer(status, {:ok, payload}), do: {status, payload}

  defp answer(_status, {:error, :invalid_cursor}),
    do: {:unprocessable_entity, MyOffers.invalid_cursor()}

  defp answer(_status, {:error, {:invalid, messages}}),
    do: {:unprocessable_entity, ApiError.invalid(messages)}

  defp answer(_status, {:error, {:not_enough_credits, words}}) do
    refuse(
      :unprocessable_entity,
      "not_enough_credits",
      words,
      "Nothing was held. The person can buy Credits from Buy Credits on their Patchbay Account page."
    )
  end

  defp answer(_status, {:error, {:agent_spending, words}}) do
    refuse(
      :forbidden,
      "agent_spending_refused",
      words,
      "Nothing was held. Agent spending isn't open yet, so your bids are turned down. Your person can bid from their own account."
    )
  end

  defp answer(_status, {:error, {:agent_not_paired, words}}) do
    {_words, hint} = PairedAgent.words(:agent_not_paired)
    refuse(:forbidden, "agent_not_paired", words, hint)
  end

  defp answer(_status, {:error, {:refused, words}}) do
    refuse(
      :unprocessable_entity,
      "bid_refused",
      words,
      "Nothing was held. Read get_offer_bid_options again and bid with what it gives."
    )
  end

  defp answer(_status, {:error, {:not_saved, words}}) do
    refuse(
      :unprocessable_entity,
      "not_saved",
      words,
      "Change what the message names, then send it again."
    )
  end

  defp answer(_status, {:error, {:unavailable, words}}),
    do: refuse(:service_unavailable, "unavailable", words, "Try again in a moment.")

  defp refuse(status, code, words, hint), do: {status, ApiError.body(code, words, hint)}
end
