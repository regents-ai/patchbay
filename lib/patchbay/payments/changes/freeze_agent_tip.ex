defmodule Patchbay.Payments.Changes.FreezeAgentTip do
  @moduledoc """
  Settles the terms of a tip at the moment it is prepared: which wallet the
  money goes to, how much, the sentence the payer is shown, and a digest over
  all of it.

  A payer signs for an amount and a destination, and what the facilitator
  settles has to be the same amount and destination they were shown. Writing
  those values once, here, is what makes that true: nothing later reads the
  recipient's profile again, so a wallet changed after the fact cannot redirect
  a payment already offered.
  """

  use Ash.Resource.Change

  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest
  alias Patchbay.Payments.USDC

  @window_seconds 15 * 60

  @impl true
  def change(changeset, _opts, _context) do
    with %{} = recipient <- Ash.Changeset.get_argument(changeset, :recipient),
         amount_atomic when is_integer(amount_atomic) <-
           Ash.Changeset.get_attribute(changeset, :amount_atomic) do
      freeze(changeset, recipient, amount_atomic)
    else
      _incomplete -> changeset
    end
  end

  @spec freeze(Ash.Changeset.t(), struct(), pos_integer()) :: Ash.Changeset.t()
  defp freeze(changeset, recipient, amount_atomic) do
    # The identifier is minted here rather than read back off the row, because
    # the primary key's own default is not applied until the insert itself.
    identifier = Ash.UUID.generate()
    payload = payload(recipient, amount_atomic)

    Ash.Changeset.force_change_attributes(changeset, %{
      id: identifier,
      payment_identifier: identifier,
      target_id: recipient.id,
      payload: payload,
      payload_digest: payload |> CanonicalJSON.encode() |> Digest.sha256(),
      recipient_snapshot: [
        %{
          "profile_id" => recipient.id,
          "wallet_address" => recipient.wallet_address,
          "amount_atomic" => amount_atomic
        }
      ],
      effect_summary: effect_summary(recipient, amount_atomic),
      expires_at: DateTime.add(DateTime.utc_now(), @window_seconds, :second)
    })
  end

  @spec payload(struct(), pos_integer()) :: map()
  defp payload(recipient, amount_atomic) do
    %{
      "recipient_public_id" => recipient.public_id,
      "pay_to_address" => recipient.wallet_address,
      "recipient_agent_name" => recipient.agent_name,
      "amount_atomic" => amount_atomic
    }
  end

  @spec effect_summary(struct(), pos_integer()) :: String.t()
  defp effect_summary(recipient, amount_atomic) do
    "Credit #{recipient.agent_name} (#{recipient.public_id}) " <>
      "#{USDC.format(amount_atomic)} USDC directly to their wallet"
  end
end
