defmodule Patchbay.Payments.SpecialPost do
  @moduledoc """
  What a settled payment for a paid priority report does: publishes the report
  exactly as the payment's terms froze it, then hands Base the request to
  record the settled money in escrow against it.

  The report comes from the frozen terms and nothing else: the id, the tool
  version, the draft and the amount are all read off the intent, and the payer
  is the actor who paid. Human reports also retain the browser session from the settling request;
  autonomous reports have no browser session and belong to their wallet author.

  The escrow credit is sent after the report is on the board, once the
  payment has landed in a Base block: the contract refuses to record money it
  does not hold yet. A credit that Base would not take is written on the
  report as `credit_failed`, with the reason in the log, for a person to send
  again with `credit_again/1`, rather than undoing a report somebody has
  paid for. A credit Base took is written
  as `credit_submitted`: the payment is received, and the bounty is
  confirmed only once the chain says the post is funded, which
  `Patchbay.Escrow.Watch` reads and records.
  """

  require Logger

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Payments
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
  Sends the escrow credit again for a report whose credit Base would not
  take, from the payment that paid for it. For a person at Patchbay, from
  the console; a report in any other state is left as it is.
  """
  @spec credit_again(Ash.UUID.t()) :: {:ok, Report.t()} | {:error, term()}
  def credit_again(report_id) do
    # A person at Patchbay re-running Patchbay's own step on a paid report,
    # so the reads are Patchbay's own.
    with {:ok, report} <- Forum.get_report(report_id, authorize?: false),
         :credit_failed <- report.escrow_status,
         {:ok, intent} <- Payments.get_payment_intent(report.payment_intent_id, authorize?: false),
         # Same as above: Patchbay's own read of the receipt that paid.
         {:ok, receipt} <-
           Ash.get(PaymentReceipt, %{payment_identifier: intent.id}, authorize?: false) do
      credit(report, intent, receipt)
    else
      status when is_atom(status) -> {:error, {:not_credit_failed, status}}
      {:error, error} -> {:error, error}
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
      with :ok <- Escrow.await_landed(receipt.transaction_hash),
           {:ok, tx_hash} <-
             Escrow.credit(report.id, receipt.payer_address, intent.amount_atomic) do
        {:credit_submitted, tx_hash}
      else
        {:error, reason} ->
          Logger.warning(
            "Escrow credit for report #{report.id} was not handed to Base: #{inspect(reason)}"
          )

          {:credit_failed, nil}
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
