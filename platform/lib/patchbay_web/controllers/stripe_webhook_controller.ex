defmodule PatchbayWeb.StripeWebhookController do
  @moduledoc """
  Where Stripe tells Patchbay a card bundle was paid for, refunded or
  disputed, each of which writes a line to the buyer's Patchbay Credits.

  Only an event whose exact bytes Stripe signed with the webhook's secret is
  read. Stripe sends an event again until it is answered with a success, so a
  line that could not be written is answered with an error, and one already
  written is left as it is. Events for card payments that are not Patchbay
  bundles (the Stripe account also sells other things) are answered and left
  alone.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Payments.Credits
  alias PatchbayWeb.Forum.NotFoundError

  def create(conn, _params) do
    unless Patchbay.Stripe.configured?(), do: raise(NotFoundError)

    signature = conn |> get_req_header("stripe-signature") |> List.first()

    with {:ok, event} <- Patchbay.Stripe.verify_event(conn.assigns[:raw_body] || "", signature),
         {:ok, _outcome} <- apply_event(event) do
      json(conn, %{received: true})
    else
      {:error, :unsigned} ->
        conn |> put_status(:bad_request) |> json(%{error: "unsigned"})

      {:error, reason} ->
        Logger.error("stripe event not recorded: #{inspect(reason)}")
        conn |> put_status(:internal_server_error) |> json(%{error: "not_recorded"})
    end
  end

  defp apply_event(%{
         "type" => "checkout.session.completed",
         "data" => %{
           "object" => %{
             "metadata" => %{"patchbay_profile_id" => profile_id},
             "payment_status" => "paid",
             "amount_total" => cents,
             "payment_intent" => payment_intent_id
           }
         }
       }),
       do: Credits.record_card_purchase(profile_id, cents, payment_intent_id)

  defp apply_event(%{
         "type" => "charge.refunded",
         "data" => %{
           "object" => %{"payment_intent" => payment_intent_id, "amount_refunded" => cents}
         }
       })
       when is_binary(payment_intent_id),
       do: Credits.record_card_refund(payment_intent_id, cents)

  defp apply_event(%{
         "type" => "charge.dispute.created",
         "data" => %{
           "object" => %{
             "id" => dispute_id,
             "payment_intent" => payment_intent_id,
             "amount" => cents
           }
         }
       })
       when is_binary(payment_intent_id),
       do: Credits.record_card_dispute(payment_intent_id, dispute_id, cents)

  defp apply_event(_not_a_bundle), do: {:ok, :not_ours}
end
