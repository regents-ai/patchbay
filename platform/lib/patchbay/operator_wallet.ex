defmodule Patchbay.OperatorWallet do
  @moduledoc """
  What the operator wallet's own sends leave waiting, for the chain numbers
  Sentinel reads (`PatchbayWeb.Telemetry`, the site poller).

  The operator wallet sends two things whose answer the site waits for and
  writes down: a paid priority report's escrow credit, `credit_submitted`
  until `Patchbay.Escrow.Watch` reads it confirmed, and an assist fee's
  deposit to REGENT staking, `forwarding` while its job waits for the chain
  (`Patchbay.Assist.Forward`). The escrow's payouts, refunds and revenue
  pushes are written down as soon as Base takes them, so the site keeps no
  unconfirmed state for them.

  Beside those ages are Patchbay's own two numbers: paid priority reports
  whose money the escrow has not yet confirmed as recorded, and the USDC of
  assist fees the operator wallet still holds, waiting, being forwarded or
  failed for a person to look at.
  """

  require Ash.Query

  alias Patchbay.Assist.Run
  alias Patchbay.Forum.Report
  alias RegentPayments.PaymentIntent

  @usdc_atomic 1_000_000

  @doc """
  Each sending flow with when its oldest unconfirmed send was signed, or nil
  when nothing waits. An escrow credit is handed to Base as its report is
  filed, so it is aged from the filing; a fee's forward from when it was
  taken.
  """
  @spec unconfirmed_sends() :: [{String.t(), DateTime.t() | nil}]
  def unconfirmed_sends do
    # The site's own rows, read for its health numbers on no one's behalf.
    [
      {"escrow_credit",
       Report
       |> Ash.Query.filter(escrow_status == :credit_submitted)
       |> Ash.min!(:inserted_at, authorize?: false)},
      {"fee_forward",
       Run
       |> Ash.Query.filter(deposit_status == :forwarding)
       |> Ash.min!(:updated_at, authorize?: false)}
    ]
  end

  @doc """
  Paid priority reports whose money the escrow contract has not yet
  confirmed: nobody has handed the credit over, Base has not confirmed it,
  or Base would not take it.
  """
  @spec escrow_unrecorded() :: non_neg_integer()
  def escrow_unrecorded do
    # The site's own rows, read for its health numbers on no one's behalf.
    Report
    |> Ash.Query.filter(
      not is_nil(priority_amount_atomic) and
        (is_nil(escrow_status) or escrow_status in [:credit_submitted, :credit_failed])
    )
    |> Ash.count!(authorize?: false)
  end

  @doc "USDC of assist fees in the operator wallet not yet deposited to staking."
  @spec assist_fees_unforwarded_usdc() :: float()
  def assist_fees_unforwarded_usdc do
    # The site's own rows, read for its health numbers on no one's behalf.
    intent_ids =
      Run
      |> Ash.Query.filter(
        deposit_status in [:pending, :forwarding, :failed] and not is_nil(payment_intent_id)
      )
      |> Ash.Query.select([:payment_intent_id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.payment_intent_id)

    atomic =
      case intent_ids do
        [] ->
          0

        ids ->
          PaymentIntent
          |> Ash.Query.filter(id in ^ids)
          |> Ash.sum!(:amount_atomic, authorize?: false) || 0
      end

    atomic / @usdc_atomic
  end
end
