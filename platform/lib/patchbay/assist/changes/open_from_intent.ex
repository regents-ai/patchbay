defmodule Patchbay.Assist.Changes.OpenFromIntent do
  @moduledoc """
  Fills a run in from the frozen terms of the settled payment that bought it.

  The id, the payment, where its fee stands and every field of the request
  are read off the intent and nothing else, so the run is the one the payer
  was shown. An intent that
  is not a settled assist payment of the actor's own opens nothing.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Payments.PaymentIntent

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.get_argument(changeset, :intent) do
      %PaymentIntent{kind: :jev_assist, status: :settled, actor_profile_id: payer} = intent
      when is_map_key(context, :actor) ->
        if match?(%{id: ^payer}, context.actor),
          do: open(changeset, intent),
          else: refuse(changeset)

      %PaymentIntent{} ->
        refuse(changeset)

      _absent ->
        changeset
    end
  end

  defp open(changeset, intent) do
    %{"run_id" => run_id, "request" => request} = intent.payload

    Ash.Changeset.force_change_attributes(changeset, %{
      id: run_id,
      payment_intent_id: intent.id,
      goal: request["goal"],
      site_url: request["site_url"],
      expected_result: request["expected_result"],
      sign_in: request["sign_in"],
      believed_calls: request["believed_calls"],
      deposit_status: deposit_status(intent)
    })
  end

  # A fee paid in USDC waits in the operator wallet to be forwarded; one paid
  # from Patchbay Credits has nothing on Base to forward.
  defp deposit_status(%PaymentIntent{paid_with: :usdc}), do: :pending
  defp deposit_status(%PaymentIntent{paid_with: :credits}), do: :card

  defp refuse(changeset) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(
        field: :intent,
        message: "must be the actor's own settled payment for an assist"
      )
    )
  end
end
