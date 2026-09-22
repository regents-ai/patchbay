defmodule Patchbay.Forum.SolutionAccept do
  @moduledoc """
  The asker of a paid priority report names the reply that answered it, and
  the money held for the report goes to that reply's author.

  Nothing a caller sends names the asker: the actor is whoever the door
  verified, a profile signed in on a page or the wallet that paid, proven by
  its signature. The report is held under a row lock while the reply is
  checked and marked, so two accepts arriving at once cannot both get
  through, and the payout is only sent once the mark is written. A payout
  that does not go through is written on the report for a person to re-run,
  never retried here.

  A bounty held in Patchbay Credits has no chain to wait on: the award is a
  line on the author's ledger, written in the same transaction as the mark,
  so the answer is accepted and paid together or not at all.
  """

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Payments.Credits

  @doc """
  Marks `reply_id` as the answer to `report_id` for `actor` and sends the
  payout. The report comes back as it stands afterwards, with the accepted
  reply and its author loaded.
  """
  @spec run(String.t(), String.t() | nil, struct() | nil) ::
          {:ok, Report.t()} | {:error, term()}
  def run(report_id, reply_id, actor) do
    with {:ok, accepted} <- accept(actor, report_id, reply_id),
         {:ok, released} <- release(accepted) do
      {:ok, %{released | accepted_reply: accepted.accepted_reply}}
    end
  end

  # The check and the mark happen under one row lock, so a second accept that
  # arrives while the first is being written waits for it and is then refused,
  # before anything reaches the chain.
  defp accept(actor, id, reply_id) do
    case Ash.transact([Report], fn -> mark(actor, id, reply_id) end) do
      {:ok, {:ok, accepted}} -> {:ok, accepted}
      {:error, failure} -> {:error, failure}
    end
  end

  defp mark(actor, id, reply_id) do
    with {:ok, report} <- locked_report(actor, id),
         {:ok, accepted} <-
           Forum.accept_reply(report, reply_id, actor: actor, load: [accepted_reply: [:author]]) do
      award(accepted)
    end
  end

  defp award(%Report{bounty_paid_with: :credits} = accepted) do
    with {:ok, _line} <-
           Credits.pay_bounty(:bounty_award, accepted, accepted.accepted_reply.author_profile_id),
         {:ok, released} <- record_release(accepted, :released, nil) do
      {:ok, %{released | accepted_reply: accepted.accepted_reply}}
    end
  end

  defp award(accepted), do: {:ok, accepted}

  defp locked_report(actor, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found_or_missing(Forum.lock_report(uuid, actor: actor))
      :error -> {:error, :not_found}
    end
  end

  defp found_or_missing({:ok, nil}), do: {:error, :not_found}
  defp found_or_missing({:ok, record}), do: {:ok, record}

  defp found_or_missing({:error, error}) do
    if missing?(error), do: {:error, :not_found}, else: {:error, error}
  end

  @doc "Whether an error means there is no such report."
  @spec missing?(term()) :: boolean()
  def missing?(%Ash.Error.Query.NotFound{}), do: true
  def missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  def missing?(_error), do: false

  # A bounty held in credits was paid with the mark. For one in USDC, the
  # winner's wallet is the one on the profile that wrote the reply, read now,
  # because that is who the asker chose to pay.
  defp release(%Report{bounty_paid_with: :credits} = released), do: {:ok, released}

  defp release(accepted) do
    case Escrow.release(accepted.id, accepted.accepted_reply.author.wallet_address) do
      {:ok, tx_hash} -> record_release(accepted, :released, tx_hash)
      {:error, _reason} -> release_refused(accepted)
    end
  end

  # A payout Base refused while it has not yet confirmed the bounty is held
  # changes nothing on the record: the bounty is still waiting on Base, and
  # writing the refusal over that would lose the confirmation when it comes.
  # The answer still says the payout has not happened.
  defp release_refused(%Report{escrow_status: :credit_submitted} = accepted), do: {:ok, accepted}
  defp release_refused(accepted), do: record_release(accepted, :release_failed, nil)

  defp record_release(accepted, status, tx_hash) do
    # Nothing over HTTP may write what the escrow said; this is the one place
    # that hears it, so the write is made deliberately without an actor.
    Forum.record_escrow_release(
      accepted,
      %{escrow_status: status, escrow_release_tx_hash: tx_hash},
      authorize?: false
    )
  end
end
