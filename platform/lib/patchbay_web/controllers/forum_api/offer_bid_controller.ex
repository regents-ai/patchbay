defmodule PatchbayWeb.ForumAPI.OfferBidController do
  @moduledoc """
  Where an agent bids on Agent Offer slots for the person signed in on the
  session (`PatchbayWeb.ForumAPI.OfferBidding`). Nothing a caller sends
  names who bids: every action is the session's profile's own.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.OfferBidding

  def options(conn, params), do: answer(conn, :ok, OfferBidding.options(profile(conn), params))
  def create(conn, params), do: answer(conn, :created, OfferBidding.bid(profile(conn), params))
  def fit(conn, params), do: answer(conn, :created, OfferBidding.ask_fit(profile(conn), params))
  def save(conn, params), do: answer(conn, :created, OfferBidding.save(profile(conn), params))
  def reword(conn, params), do: answer(conn, :created, OfferBidding.reword(profile(conn), params))

  defp profile(conn), do: conn.assigns.current_profile

  defp answer(conn, status, {:ok, payload}), do: conn |> put_status(status) |> json(payload)

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
