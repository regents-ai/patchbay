defmodule Patchbay.Payments.SpecialPost do
  @moduledoc """
  What a settled payment for a paid priority report does: publishes the report
  exactly as the payment's terms froze it, then records the settled money in
  escrow against it.

  The report comes from the frozen terms and nothing else: the id, the tool
  version, the draft and the amount are all read off the intent, and the payer
  is the actor who paid. Only the browser session comes from the request that
  settled it, because a report is filed under the session that posted it.

  The escrow credit is sent after the report is on the board. The money is
  already in the contract by then, so a credit that does not go through is
  written on the report as `credit_failed` for a person to re-run, rather
  than undoing a report somebody has paid for.
  """

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Payments.PaymentIntent
  alias Patchbay.Payments.PaymentReceipt

  @doc """
  Publishes the report a settled intent paid for and records its escrow
  credit. The actor is the payer; the session is the one the settling request
  carries.
  """
  @spec publish(PaymentIntent.t(), PaymentReceipt.t(),
          actor: struct(),
          browser_session_id: String.t()
        ) ::
          {:ok, Report.t()} | {:error, term()}
  def publish(%PaymentIntent{kind: :special_post} = intent, %PaymentReceipt{} = receipt, opts) do
    actor = Keyword.fetch!(opts, :actor)
    browser_session_id = Keyword.fetch!(opts, :browser_session_id)

    with {:ok, report} <- file(intent, actor, browser_session_id) do
      credit(report, intent, receipt)
    end
  end

  defp file(intent, actor, browser_session_id) do
    %{"report_id" => report_id, "tool_id" => tool_id, "draft" => draft} = intent.payload

    draft
    |> OtherSiteReport.report_attributes(tool_id)
    |> Map.merge(%{
      id: report_id,
      browser_session_id: browser_session_id,
      priority_amount_atomic: intent.amount_atomic,
      payment_intent_id: intent.id
    })
    |> Forum.file_priority_report(actor: actor)
  end

  defp credit(report, intent, receipt) do
    {status, tx_hash} =
      case Escrow.credit(report.id, receipt.payer_address, intent.amount_atomic) do
        {:ok, tx_hash} -> {:credited, tx_hash}
        {:error, _reason} -> {:credit_failed, nil}
      end

    # The contract stamps its own funding moment and counts the refund delay
    # from that; this is Patchbay's note of the same moment, for telling a
    # reader when the bounty comes free. The chain is what enforces it.
    funded_at = if status == :credited, do: DateTime.utc_now()

    # Nothing over HTTP may write what the escrow said; this is the one place
    # that hears it, so the write is made deliberately without an actor.
    Forum.record_escrow_credit(
      report,
      %{escrow_status: status, escrow_credit_tx_hash: tx_hash, escrow_funded_at: funded_at},
      authorize?: false
    )
  end
end
