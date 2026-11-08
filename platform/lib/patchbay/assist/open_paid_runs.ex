defmodule Patchbay.Assist.OpenPaidRuns do
  @moduledoc """
  Opens, every hour, the run of each paid assist that settled without one,
  once its payer has no run open.

  A paid assist's run opens in the same transaction that marks its payment
  applied. When it cannot (the payer opened a free fix between asking and
  paying, say), the payment stays settled with no run. Here each such payment
  of a person is finished as its payer finishes it on their next call
  (`RegentPayments.Purchase.complete/3`, from the payer's profile as the
  payment names it), so the run opens from the same frozen terms, once, and
  its work is queued with it. The run belongs to the payer and to no browser.

  A payment an agent made is finished only by that agent while its pairing
  still stands, so it waits for the agent's next call; the fee it paid is
  counted with the fees the operator wallet holds until then
  (`Patchbay.OperatorWallet.assist_fees_unforwarded_usdc/0`).
  """

  use Oban.Worker, queue: :assist, max_attempts: 1

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Patchbay.Identity
  alias RegentPayments.AgentAuthority

  @impl Oban.Worker
  def perform(_job) do
    # A payer's oldest payment opens its run; the next waits for that run to close.
    waiting()
    |> Enum.uniq_by(fn {_intent_id, payer_id} -> payer_id end)
    |> Enum.each(fn {intent_id, payer_id} -> open(intent_id, payer_id) end)
  end

  @doc """
  Each paid assist of a person settled with no run, whose payer has no run
  open, oldest first, as its intent's id and its payer's profile id.
  """
  @spec waiting() :: [{Ash.UUID.t(), Ash.UUID.t()}]
  def waiting do
    # One read over the payments library's intents and the site's runs, which
    # are in different schemas (`Patchbay.OperatorWallet` reads them the same way).
    Patchbay.Repo.all(
      from(intent in "payment_intents",
        as: :intent,
        prefix: "regent_payments",
        left_join: run in "assist_runs",
        on: run.payment_intent_id == intent.id,
        where:
          intent.site == "patchbay" and intent.kind == "jev_assist" and
            intent.status == "settled" and is_nil(run.id) and
            is_nil(fragment("? -> ?", intent.payload, ^AgentAuthority.key())) and
            not exists(
              from(open in "assist_runs",
                where:
                  open.payer_profile_id == parent_as(:intent).actor_profile_id and
                    open.status in ["paid", "running"],
                select: 1
              )
            ),
        order_by: [asc: intent.inserted_at],
        select: {type(intent.id, Ecto.UUID), type(intent.actor_profile_id, Ecto.UUID)}
      )
    )
  end

  defp open(intent_id, payer_id) do
    # The payer's profile as the payment names it, read by Patchbay's own job.
    with {:ok, payer} <-
           Identity.get_profile(payer_id, load: [:wallet_addresses], authorize?: false),
         {:applied, _intent, _receipt} <-
           RegentPayments.Purchase.complete(payer, intent_id, %{browser_session_id: nil}) do
      :ok
    else
      other ->
        Logger.warning(
          "Assist payment #{intent_id} of #{payer_id} is settled and its run did not open: #{inspect(other)}"
        )
    end
  end
end
