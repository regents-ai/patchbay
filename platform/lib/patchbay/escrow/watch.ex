defmodule Patchbay.Escrow.Watch do
  @moduledoc """
  Patchbay watching Base for what the escrow contract did with bounties.

  The board only learns what the contract did by asking it. This is the
  `:read_escrow` action of `Patchbay.Forum.Report`, run one report at a time
  by two triggers: every minute for a bounty with a request sent and not yet
  confirmed (`:read_escrow_sent`), and every five minutes for one the board
  believes is held or a send failed for (`:read_escrow_held`). Each asks the
  contract what it holds for the report's post and settles the board's state
  against that answer:

    * the contract sent the money back: the refund is written, whatever the
      board believed, since thirty days after a bounty is funded anybody may
      refund it without Patchbay being asked;
    * the contract paid it out: the payout is written, for a payout sent or
      one written as failed that went through after all;
    * the contract holds it, from the wallet and for the amount that paid: a
      credit sent, or one written as failed that went through after all, is
      written as confirmed, with the chain's own funding time;
    * the contract holds it while a payout was sent: the payout's receipt is
      read, and a payout the contract refused, or one still not in a block an
      hour after it was sent, is written as failed for a person to send again;
    * the contract holds nothing while a credit was sent: the credit's
      receipt is read, and a credit the contract refused, or one still not in
      a block an hour after it was sent, is written as failed for a person to
      send again.

  Anything else leaves the report as it is, and a state that has waited too
  long, or that only a person can move, is logged for one to look at. The
  question to Base is asked outside any transaction and only what it answered
  is written, through actions that refuse to move a bounty that has moved on
  meanwhile. It never moves money and never sends anything, so a read that
  cannot reach Base changes nothing and the next sweep asks again. It does
  nothing at all while no escrow is configured.
  """

  use Ash.Resource.ManualUpdate

  require Logger

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Payments.SpecialPost

  # How long a credit or a payout may go without landing in a block before it
  # is taken not to have been sent at all.
  @landing_window_s 3_600

  @impl true
  def update(changeset, _opts, _context) do
    report = changeset.data

    if Escrow.contract_address(),
      do: {:ok, read(report)},
      else: {:ok, report}
  end

  defp read(report) do
    case Escrow.post(report.id) do
      {:ok, post} -> settle(report, post)
      {:error, _reason} -> unread(report)
    end
  end

  defp settle(report, %{status: :refunded}), do: refunded(report)

  defp settle(%{escrow_status: status} = report, %{status: :released})
       when status in [:release_submitted, :release_failed],
       do: released(report)

  defp settle(%{escrow_status: status} = report, %{status: :funded} = post)
       when status in [:credit_submitted, :credit_failed],
       do: confirm_as_paid(report, post)

  defp settle(%{escrow_status: :release_submitted} = report, %{status: :funded}),
    do: release_receipt(report)

  defp settle(%{escrow_status: :credit_submitted} = report, %{status: :none}),
    do: credit_receipt(report)

  defp settle(%{escrow_status: :credited} = report, %{status: :funded}), do: report

  defp settle(%{escrow_status: :credit_failed} = report, %{status: :none}),
    do: attention(report, "its credit failed and is not on Base; send it again")

  defp settle(%{escrow_status: :release_failed} = report, %{status: :funded}),
    do: attention(report, "its payout failed and the money is still held; send it again")

  defp settle(report, post),
    do: attention(report, "the board says #{report.escrow_status}, the contract #{post.status}")

  # A funded post confirms this bounty only when it is the one that was
  # paid: the same amount, from the wallet the receipt names.
  defp confirm_as_paid(report, post) do
    cond do
      post.amount != report.priority_amount_atomic ->
        attention(
          report,
          "the contract holds #{post.amount}, not #{report.priority_amount_atomic}"
        )

      post.payer != paying_wallet(report) ->
        attention(report, "the contract names a different payer")

      true ->
        Forum.confirm_escrow_credit(report, %{escrow_funded_at: post.funded_at},
          authorize?: false
        )
        |> written(report, "confirmed")
    end
  end

  # The wallet the receipt names, downcased as the contract names it, or nil
  # when the payment cannot be found, which no funded post can match.
  defp paying_wallet(report) do
    case RegentPayments.get_payment_intent(report.payment_intent_id,
           load: [:receipt],
           authorize?: false
         ) do
      {:ok, %{receipt: %{payer_address: payer}}} -> String.downcase(payer)
      _missing -> nil
    end
  end

  defp credit_receipt(report) do
    case Escrow.outcome(report.escrow_credit_tx_hash) do
      {:ok, :reverted} ->
        credit_failed(report)

      {:error, :not_landed} ->
        if lost?(report.escrow_credit_sent_at),
          do: credit_failed(report),
          else: still_waiting(report)

      _succeeded_or_unread ->
        still_waiting(report)
    end
  end

  defp release_receipt(report) do
    case Escrow.outcome(report.escrow_release_tx_hash) do
      {:ok, :reverted} ->
        release_failed(report)

      {:error, :not_landed} ->
        if lost?(report.escrow_release_sent_at), do: release_failed(report), else: report

      _succeeded_or_unread ->
        report
    end
  end

  defp lost?(sent_at), do: DateTime.diff(DateTime.utc_now(), sent_at) >= @landing_window_s

  defp still_waiting(report) do
    if SpecialPost.overdue?(report) do
      attention(
        report,
        "unconfirmed #{SpecialPost.attention_after_minutes()} minutes after hand-over"
      )
    else
      report
    end
  end

  # Base not answering is not Base saying no. The error itself stays out of
  # the log, since a transport error can carry the address it was sent to.
  defp unread(report) do
    Logger.warning("escrow watch: Base could not be read for report #{report.id}")
    report
  end

  defp attention(report, why) do
    Logger.warning("escrow watch: bounty on report #{report.id} needs a person: #{why}")
    report
  end

  # Recording what the chain said is nobody's request: no actor is on this
  # path, and no policy names the writes, so each is made without one.
  defp refunded(report) do
    report
    |> PriorityRefund.record(report.escrow_refund_tx_hash)
    |> written(report, "refunded")
  end

  defp released(report), do: move(report, &Forum.confirm_escrow_release/2, "paid out")
  defp credit_failed(report), do: move(report, &Forum.fail_escrow_credit/2, "credit failed")
  defp release_failed(report), do: move(report, &Forum.fail_escrow_release/2, "payout failed")

  # Written without an actor, as every record of what Base said.
  defp move(report, step, what), do: report |> step.(authorize?: false) |> written(report, what)

  defp written({:ok, moved}, report, what) do
    Logger.info("escrow watch: bounty on report #{report.id} #{what} on Base")
    moved
  end

  defp written({:error, reason}, report, what) do
    Logger.warning(
      "escrow watch could not write report #{report.id} as #{what}: #{inspect(reason)}"
    )

    report
  end
end
