defmodule Patchbay.Payments.SpecialPost do
  @moduledoc """
  What a settled payment for a paid priority report does: publishes the report
  exactly as the payment's terms froze it, then hands Base the request to
  record the settled money in escrow against it.

  The report comes from the frozen terms and nothing else: the id, the tool
  version, the draft and the amount are all read off the intent, and the payer
  is the actor who paid. Human reports also retain the browser session from the settling request;
  autonomous reports have no browser session and belong to their wallet author.

  The escrow credit is sent after the report is on the board. The money is
  already in the contract by then, so a credit that Base would not take is
  written on the report as `credit_failed` for a person to re-run, rather
  than undoing a report somebody has paid for. A credit Base took is written
  as `credit_submitted`: the payment is received, and the bounty is
  confirmed only once the chain says the post is funded, which
  `Patchbay.Escrow.Watch` reads and records.
  """

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Payments.PaymentIntent
  alias Patchbay.Payments.PaymentReceipt

  # How long a handed-over credit may go unconfirmed before it is a matter
  # for a person, not a failure: Base is still asked, and a late confirmation
  # still counts.
  @attention_after_minutes 30

  @doc """
  Publishes the report a settled intent paid for and hands over its escrow
  credit. The actor is the payer; the session is the one the settling request
  carries.
  """
  @spec publish(PaymentIntent.t(), PaymentReceipt.t(),
          actor: struct(),
          browser_session_id: String.t() | nil
        ) ::
          {:ok, Report.t()} | {:error, term()}
  def publish(%PaymentIntent{kind: :special_post} = intent, %PaymentReceipt{} = receipt, opts) do
    actor = Keyword.fetch!(opts, :actor)
    browser_session_id = Keyword.fetch!(opts, :browser_session_id)

    with {:ok, report} <- file(intent, actor, browser_session_id) do
      credit(report, intent, receipt)
    end
  end

  @doc """
  Where a paid report's bounty stands as a fact apart from its payment:
  `:pending` while Base has the credit and has not confirmed it, `:confirmed`
  once the chain recorded it (and thereafter, whatever the money did next),
  and `:needs_attention` when Base would not take the credit or has gone
  #{@attention_after_minutes} minutes without confirming it. Nothing here
  moves money, and nothing here is a reason to pay again.
  """
  @spec confirmation(Report.t()) :: :pending | :confirmed | :needs_attention
  def confirmation(%Report{escrow_status: :credit_submitted} = report) do
    if overdue?(report), do: :needs_attention, else: :pending
  end

  def confirmation(%Report{escrow_status: status})
      when status in [:credit_failed, nil],
      do: :needs_attention

  def confirmation(%Report{}), do: :confirmed

  @doc "Whether a handed-over credit has waited long enough to need a person."
  @spec overdue?(Report.t()) :: boolean()
  def overdue?(%Report{escrow_status: :credit_submitted, inserted_at: filed_at}) do
    DateTime.diff(DateTime.utc_now(), filed_at, :minute) >= @attention_after_minutes
  end

  def overdue?(%Report{}), do: false

  @spec attention_after_minutes() :: pos_integer()
  def attention_after_minutes, do: @attention_after_minutes

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
        {:ok, tx_hash} -> {:credit_submitted, tx_hash}
        {:error, _reason} -> {:credit_failed, nil}
      end

    # Nothing over HTTP may write what the escrow said; this is the one place
    # that hears it, so the write is made deliberately without an actor.
    Forum.record_escrow_credit(
      report,
      %{escrow_status: status, escrow_credit_tx_hash: tx_hash},
      authorize?: false
    )
  end
end
