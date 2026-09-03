defmodule Patchbay.Payments.Changes.FreezeSpecialPost do
  @moduledoc """
  Settles the terms of a paid priority report at the moment it is prepared:
  the report exactly as the asker drafted it, the tool version it is about,
  the escrow the money goes to, how much, the id the report will be published
  under, the sentence the payer is shown, and a digest over all of it.

  The report is published from these terms after the money settles and from
  nothing else, so a draft changed after the fact cannot be what gets filed,
  and the escrow address a payer signs for is the one written here.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Escrow
  alias Patchbay.Forum.Tool
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest
  alias Patchbay.Payments.USDC

  @window_seconds 15 * 60

  @not_set_up "Paid priority posts are not set up on this Patchbay."

  @impl true
  def change(changeset, _opts, _context) do
    with %Tool{} = tool <- Ash.Changeset.get_argument(changeset, :tool),
         %{} = draft <- Ash.Changeset.get_argument(changeset, :draft),
         amount_atomic when is_integer(amount_atomic) <-
           Ash.Changeset.get_attribute(changeset, :amount_atomic) do
      freeze(changeset, tool, draft, amount_atomic, Escrow.contract_address())
    else
      _incomplete -> changeset
    end
  end

  # Terms with nowhere for the money to go are no terms at all.
  defp freeze(changeset, _tool, _draft, _amount_atomic, nil) do
    Ash.Changeset.add_error(changeset, InvalidChanges.exception(message: @not_set_up))
  end

  defp freeze(changeset, tool, draft, amount_atomic, escrow_address) do
    # Both ids are minted here rather than read back off a row, because the
    # report does not exist yet and the intent's own default is not applied
    # until the insert itself.
    identifier = Ash.UUID.generate()
    report_id = Ash.UUID.generate()
    payload = payload(report_id, tool, draft, amount_atomic, escrow_address)

    Ash.Changeset.force_change_attributes(changeset, %{
      id: identifier,
      payment_identifier: identifier,
      target_id: report_id,
      payload: payload,
      payload_digest: payload |> CanonicalJSON.encode() |> Digest.sha256(),
      recipient_snapshot: [
        %{"wallet_address" => escrow_address, "amount_atomic" => amount_atomic}
      ],
      effect_summary: effect_summary(tool, amount_atomic),
      expires_at: DateTime.add(DateTime.utc_now(), @window_seconds, :second)
    })
  end

  defp payload(report_id, tool, draft, amount_atomic, escrow_address) do
    %{
      "report_id" => report_id,
      "tool_id" => tool.id,
      "draft" => draft,
      "pay_to_address" => escrow_address,
      "amount_atomic" => amount_atomic
    }
  end

  defp effect_summary(tool, amount_atomic) do
    "Hold #{USDC.format(amount_atomic)} USDC in escrow for a paid priority report on " <>
      "#{tool.name} at #{tool.site.origin}; the accepted answer's author receives 90% " <>
      "and Patchbay 10%"
  end
end
