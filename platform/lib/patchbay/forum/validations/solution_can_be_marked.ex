defmodule Patchbay.Forum.Validations.SolutionCanBeMarked do
  @moduledoc """
  The rules a reply must meet before an asker may call it what worked: the
  reply exists, it is published, it belongs to this thread, the thread is
  still taking answers, and the person asking is the thread's own asker — the
  signed-in profile that posted it or the browser session it came from.

  A thread with money still held for it refuses outright: its answer is named
  by the award flow, so the ordinary mark can never quietly stand in for the
  prize or point at a different recipient.
  """

  use Ash.Resource.Validation

  alias Patchbay.Forum
  alias Patchbay.Forum.SolutionRefused

  @impl true
  def validate(changeset, _opts, context) do
    report = changeset.data
    session_id = Ash.Changeset.get_argument(changeset, :browser_session_id)
    reply_id = Ash.Changeset.get_argument(changeset, :reply_id)

    if asker?(report, session_id, context.actor) do
      report
      |> no_money_waiting()
      |> then_ok(fn -> open_to_answers(report) end)
      |> then_ok(fn -> reply_on_this_thread(report, reply_id, context.actor) end)
    else
      refuse(:not_asker)
    end
  end

  defp then_ok(:ok, next), do: next.()
  defp then_ok(error, _next), do: error

  # A persistent public wallet author never transfers the previous owner's
  # thread rights when that wallet is paired with a different account.
  defp asker?(report, _session, %Patchbay.Agents.Actor{} = actor),
    do: Patchbay.Forum.Principal.for(report) in actor.principals

  defp asker?(%{author_profile_id: profile_id}, _session, %{id: id})
       when is_binary(profile_id) and profile_id == id,
       do: true

  defp asker?(%{browser_session_id: asked}, session_id, _actor)
       when is_binary(session_id) and asked == session_id,
       do: true

  defp asker?(_report, _session, _actor), do: false

  @impl true
  def describe(_opts), do: [message: "cannot be marked as the solution", vars: []]

  # `bounty_open` without the calculation loaded: money named and not yet
  # refunded means the award flow chooses, never this one.
  defp no_money_waiting(%{priority_amount_atomic: amount, escrow_status: escrow})
       when is_integer(amount) do
    if escrow == :refunded, do: :ok, else: refuse(:award_pending)
  end

  defp no_money_waiting(_report), do: :ok

  defp open_to_answers(%{discussion_state: :closed}) do
    refuse(:thread_closed)
  end

  defp open_to_answers(_report), do: :ok

  # A reply that does not exist is not on this thread either; a read that
  # failed is not a refusal and goes back as the failure it is.
  defp reply_on_this_thread(_report, nil, _actor), do: refuse(:reply_not_on_thread)

  defp reply_on_this_thread(report, reply_id, actor) do
    case Forum.get_reply(reply_id, actor: actor) do
      {:ok, %{report_id: report_id, visibility: :published}} when report_id == report.id -> :ok
      {:ok, _reply} -> refuse(:reply_not_on_thread)
      {:error, failure} -> missing_or_failed(failure)
    end
  end

  defp missing_or_failed(%Ash.Error.Invalid{errors: errors} = failure) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
      do: refuse(:reply_not_on_thread),
      else: {:error, failure}
  end

  defp missing_or_failed(failure), do: {:error, failure}

  defp refuse(reason), do: {:error, SolutionRefused.exception(reason: reason)}
end
