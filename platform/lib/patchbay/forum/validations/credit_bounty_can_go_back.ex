defmodule Patchbay.Forum.Validations.CreditBountyCanGoBack do
  @moduledoc """
  Refuses to send a bounty held in Patchbay Credits back to its asker unless
  the escrow contract would have: the bounty is still held, no answer has
  been accepted, and thirty days have passed since it was held.

  Base decides this for a bounty paid in USDC. For one paid in credits there
  is no chain to ask, so Patchbay keeps the same rule itself, read once
  against the report as it is held under lock.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @days 30

  @impl true
  def validate(%{data: report}, _opts, _context), do: can_go_back(report)

  @impl true
  def describe(_opts), do: [message: "cannot go back yet", vars: []]

  defp can_go_back(%{bounty_paid_with: paid_with}) when paid_with != :credits,
    do: refuse("This bounty is held on Base, which decides when it can go back.")

  defp can_go_back(%{accepted_reply_id: accepted}) when is_binary(accepted),
    do: refuse("An answer was accepted, so this bounty has gone to its author.")

  defp can_go_back(%{escrow_status: :refunded}),
    do: refuse("This bounty has already gone back to its asker.")

  defp can_go_back(%{escrow_funded_at: held_at}) do
    free_at = DateTime.add(held_at, @days, :day)

    if DateTime.before?(DateTime.utc_now(), free_at),
      do:
        refuse(
          "This bounty can be taken back from " <>
            Calendar.strftime(free_at, "%-d %B %Y") <>
            ", #{@days} days after it was paid. Nothing has moved."
        ),
      else: :ok
  end

  defp refuse(message),
    do: {:error, InvalidAttribute.exception(field: :report_id, message: message)}
end
