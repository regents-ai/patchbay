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

  Filing the report queues its escrow credit, Base's record of the money
  against the report, in the same transaction (the report's
  `:send_escrow_credit` trigger, `Patchbay.Escrow.Send`). The money stays
  where the payment left it whatever happens to the credit: a report somebody
  has paid for is never undone. `confirmation/1` says where the bounty stands
  for the payer, from what the report has written down.
  """

  @behaviour RegentPayments.Offer

  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Tool
  alias Patchbay.Payments.Completion
  alias RegentPayments.Offer
  alias RegentPayments.USDC

  # A paid priority report holds enough to be worth answering, and no more
  # than one call may put into escrow without a person deciding.
  @min_atomic 1_000_000
  @max_atomic 100_000_000

  # How long a paid report's credit may go unconfirmed before it is a matter
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
    with {:ok, escrow_address} <- escrow_address(),
         :ok <- files?(filing(draft, tool, amount_atomic, actor)) do
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
  Where a paid report's bounty stands as a fact apart from its payment:
  `:pending` while its credit is on its way to Base or Base has it and has
  not confirmed it, `:confirmed` once the chain recorded it (and thereafter,
  whatever the money did next), and `:needs_attention` when the credit did
  not go through, or has gone #{@attention_after_minutes} minutes without
  confirmation. Nothing here moves money, and nothing here is a reason to pay
  again.
  """
  @spec confirmation(Report.t()) :: :pending | :confirmed | :needs_attention
  def confirmation(%Report{escrow_status: status} = report)
      when status in [nil, :credit_submitted] do
    if overdue?(report), do: :needs_attention, else: :pending
  end

  def confirmation(%Report{escrow_status: :credit_failed}), do: :needs_attention
  def confirmation(%Report{}), do: :confirmed

  @doc """
  Whether a paid report's credit has waited long enough to need a person:
  one not handed to Base yet, counted from the filing, and one handed over,
  from its hand-over, as Sentinel's age of it is.
  """
  @spec overdue?(Report.t()) :: boolean()
  def overdue?(%Report{escrow_status: nil, inserted_at: filed_at}), do: waited?(filed_at)

  def overdue?(%Report{escrow_status: :credit_submitted, escrow_credit_sent_at: sent_at}),
    do: waited?(sent_at)

  def overdue?(%Report{}), do: false

  defp waited?(since),
    do: DateTime.diff(DateTime.utc_now(), since, :minute) >= @attention_after_minutes

  @spec attention_after_minutes() :: pos_integer()
  def attention_after_minutes, do: @attention_after_minutes

  @doc """
  The forum's own filing action for a paid priority report of `draft` about
  `tool`, built and not written, refusing an amount outside what one report
  may hold beside every reason the forum gives. The ids and the session it is
  built with stand in for the ones the settlement will carry; none of them is
  what the forum's rules are about.
  """
  @spec filing(map(), Tool.t(), pos_integer(), struct()) :: Ash.Changeset.t()
  def filing(draft, tool, amount_atomic, actor) do
    Report
    |> Ash.Changeset.for_create(
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
    |> held(amount_atomic)
  end

  defp held(filing, amount_atomic) do
    case Offer.amount_between(amount_atomic, @min_atomic, @max_atomic) do
      :ok -> filing
      {:error, out_of_bounds} -> Ash.Changeset.add_error(filing, out_of_bounds)
    end
  end

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
  # written, and every reason it gives, the amount's included, is handed back
  # as a reason of these terms, so the report published after settlement is
  # one the forum would have accepted.
  defp files?(filing), do: if(filing.valid?, do: :ok, else: {:error, filing.errors})
end
