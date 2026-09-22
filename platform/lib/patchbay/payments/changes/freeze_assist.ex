defmodule Patchbay.Payments.Changes.FreezeAssist do
  @moduledoc """
  Settles the terms of a paid assist at the moment it is prepared: the
  request exactly as the agent wrote it, the wallet the fee goes to, how much,
  the id the run will be opened under, the sentence the payer is shown, and a
  digest over all of it.

  The run is opened from these terms after the money settles and from nothing
  else, so a request changed after the fact cannot be what Patchbay works on,
  and the wallet a payer signs for is the one written here.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Assist
  alias Patchbay.Assist.Request
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest
  alias Patchbay.Payments.USDC

  @window_seconds 15 * 60

  @not_set_up "Paid assists are not set up on this Patchbay."

  @impl true
  def change(changeset, _opts, context) do
    with %{} = request <- Ash.Changeset.get_argument(changeset, :request),
         amount_atomic when is_integer(amount_atomic) <-
           Ash.Changeset.get_attribute(changeset, :amount_atomic) do
      # The request is held to its own rules here as well as at the door, so
      # nothing reaches frozen terms that the door would have refused.
      case Request.draft(request) do
        {:ok, ^request} ->
          freeze(changeset, request, amount_atomic, Assist.pay_to_address(), context.actor)

        _refused ->
          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: :request,
              message: "must be an assist request in the fields such a request takes"
            )
          )
      end
    else
      _incomplete -> changeset
    end
  end

  # Terms with nowhere for the money to go are no terms at all.
  defp freeze(changeset, _request, _amount_atomic, nil, _actor) do
    Ash.Changeset.add_error(changeset, InvalidChanges.exception(message: @not_set_up))
  end

  defp freeze(changeset, request, amount_atomic, pay_to_address, actor) do
    # Both ids are minted here rather than read back off a row, because the
    # run does not exist yet and the intent's own default is not applied
    # until the insert itself.
    identifier = Ash.UUID.generate()
    run_id = Ash.UUID.generate()

    payload = %{
      "run_id" => run_id,
      "request" => request,
      "pay_to_address" => pay_to_address,
      "amount_atomic" => amount_atomic
    }

    payload =
      if match?(%{authentication_origin: :wallet}, actor),
        do: Map.put(payload, "author_origin", "wallet"),
        else: payload

    Ash.Changeset.force_change_attributes(changeset, %{
      id: identifier,
      payment_identifier: identifier,
      target_id: run_id,
      payload: payload,
      payload_digest: payload |> CanonicalJSON.encode() |> Digest.sha256(),
      recipient_snapshot: [
        %{"wallet_address" => pay_to_address, "amount_atomic" => amount_atomic}
      ],
      effect_summary: effect_summary(request, amount_atomic),
      expires_at: DateTime.add(DateTime.utc_now(), @window_seconds, :second)
    })
  end

  defp effect_summary(request, amount_atomic) do
    "Ask Patchbay to work out the right tool call on #{Request.host(request)} " <>
      "for #{USDC.format(amount_atomic)} USDC"
  end
end
