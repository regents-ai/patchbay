defmodule Patchbay.Payments.SpecialPost do
  @moduledoc """
  A paid priority report: the asker's money is paid into the escrow contract,
  which holds it for the answer the asker accepts.

  The terms freeze the report exactly as the asker drafted it, the tool
  version it is about, the escrow the money goes to, how much, and the id the
  report will be published under. Once the money settles, the report is
  published from those terms and nothing else, in the same transaction that
  marks the payment applied, so a draft changed after the fact cannot be what
  gets filed.

  The escrow credit, Base's record of the money against the report, is sent
  after that transaction has committed (`credit/2`), once the payment has
  landed in a Base block: the contract refuses to record money it does not
  hold yet. Each report's credit is handed over once: the hand-over is claimed
  on the report before anything is sent. A credit Base would not take is
  written on the report as `credit_failed`, with the reason in the log, for a
  person to send again with `credit_again/1`, rather than undoing a report
  somebody has paid for. A credit Base took is written as `credit_submitted`:
  the payment is received, and the bounty is confirmed only once the chain
  says the post is funded, which `Patchbay.Escrow.Watch` reads and records.
  """

  @behaviour RegentPayments.Offer

  require Logger

  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Payments.Completion
  alias RegentPayments.Offer
  alias RegentPayments.USDC

  # A paid priority report holds enough to be worth answering, and no more
  # than one call may put into escrow without a person deciding.
  @min_atomic 1_000_000
  @max_atomic 100_000_000

  # How long a handed-over credit may go unconfirmed before it is a matter
  # for a person, not a failure: Base is still asked, and a late confirmation
  # still counts.
  @attention_after_minutes 30

  @not_set_up "Paid priority posts are not set up on this Patchbay."

  @impl true
  def kind, do: :special_post

  @impl true
  def target_type, do: :report

  @impl true
  def payer?(_actor), do: true

  @doc """
  Freezes a paid priority report of `draft` about `tool` (with its site
  loaded), holding `amount_atomic` in escrow.
  """
  @impl true
  def freeze(%{tool: tool, draft: draft, amount_atomic: amount_atomic}, actor) do
    with :ok <- Offer.amount_between(amount_atomic, @min_atomic, @max_atomic),
         {:ok, escrow_address} <- escrow_address(),
         :ok <- files?(draft, tool, amount_atomic, actor) do
      # The report does not exist yet, so its id is minted here and frozen
      # with the rest.
      report_id = Ash.UUID.generate()

      {:ok,
       %{
         amount_atomic: amount_atomic,
         pay_to_address: escrow_address,
         target_id: report_id,
         payload:
           author_origin(
             %{"report_id" => report_id, "tool_id" => tool.id, "draft" => draft},
             actor
           ),
         recipient_snapshot: [
           %{"wallet_address" => escrow_address, "amount_atomic" => amount_atomic}
         ],
         effect_summary:
           "Hold #{USDC.format(amount_atomic)} USDC in escrow for a paid priority report on " <>
             "#{tool.name} at #{tool.site.origin}; the accepted answer's author receives 90% " <>
             "and 10% goes to REGENT staking"
       }}
    end
  end

  @doc """
  Publishes the report a settled intent paid for, exactly as its terms froze
  it. The payer is the actor; a report paid for on a page is filed under the
  browser `context` names, and a wallet author's has none.
  """
  @impl true
  def carry_out(intent, _receipt, actor, context) do
    with :ok <- Completion.authorize(actor, intent, kind(), target_type()) do
      %{"report_id" => report_id, "tool_id" => tool_id, "draft" => draft} = intent.payload

      filed =
        draft
        |> OtherSiteReport.report_attributes(tool_id)
        |> Map.merge(%{
          id: report_id,
          browser_session_id:
            if(actor.authentication_origin == :wallet, do: nil, else: context.browser_session_id),
          priority_amount_atomic: intent.amount_atomic,
          payment_intent_id: intent.id,
          intent: intent
        })
        |> Forum.file_priority_report(actor: actor)

      with {:ok, _report} <- filed, do: {:ok, :complete}
    end
  end

  # A report whose filing failed stays settled with its receipt, for a person
  # to publish by hand; it is never filed on a guess from a later call.
  @impl true
  def resumes?, do: false

  @doc """
  Hands Base the escrow credit for the report an applied intent published,
  when nobody has handed it over yet. Safe to call on every read of the
  intent: the hand-over is claimed on the report first, and only the call
  that claims it sends anything.
  """
  @spec credit(RegentPayments.PaymentIntent.t(), RegentPayments.PaymentReceipt.t()) :: :ok
  def credit(intent, receipt) do
    # Patchbay's own step on the report its payment published.
    with {:ok, %Report{escrow_status: nil} = report} <-
           Forum.get_report(intent.target_id, authorize?: false),
         {:ok, claimed} <- Forum.claim_escrow_credit(report, authorize?: false) do
      _ = send_credit(claimed, intent, receipt)
    end

    :ok
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
         {:ok, intent} <-
           RegentPayments.get_payment_intent(report.payment_intent_id,
             authorize?: false,
             load: [:receipt]
           ) do
      send_credit(report, intent, intent.receipt)
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

  defp escrow_address do
    case Escrow.contract_address() do
      nil -> {:error, InvalidChanges.exception(message: @not_set_up)}
      address -> {:ok, address}
    end
  end

  # A wallet author pays and reads its intent back through the wallet-signed
  # endpoints, and the terms say so.
  defp author_origin(payload, %{authentication_origin: :wallet}),
    do: Map.put(payload, "author_origin", "wallet")

  defp author_origin(payload, _actor), do: payload

  # The draft is run through the forum's own filing action, without being
  # written, and every reason the forum gives is handed back as a reason of
  # these terms, so the report published after settlement is one the forum
  # would have accepted. The ids and the session it is built with stand in
  # for the ones the settlement will carry; none of them is what the forum's
  # rules are about.
  defp files?(draft, tool, amount_atomic, actor) do
    filing =
      Ash.Changeset.for_create(
        Report,
        :file_priority_report,
        draft
        |> OtherSiteReport.report_attributes(tool.id)
        |> Map.merge(%{
          id: Ash.UUID.generate(),
          browser_session_id:
            if(actor.authentication_origin == :wallet, do: nil, else: Ash.UUID.generate()),
          priority_amount_atomic: amount_atomic,
          payment_intent_id: Ash.UUID.generate()
        }),
        actor: actor
      )

    if filing.valid?, do: :ok, else: {:error, filing.errors}
  end

  defp send_credit(report, intent, receipt) do
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
