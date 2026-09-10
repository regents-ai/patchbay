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

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Forum

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
      refuse(:reply_id, "only whoever asked may say which answer worked")
    end
  end

  defp then_ok(:ok, next), do: next.()
  defp then_ok(error, _next), do: error

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
    if escrow == :refunded,
      do: :ok,
      else:
        refuse(
          :reply_id,
          "this thread has money waiting on its answer; the answer is chosen by the award that money is for"
        )
  end

  defp no_money_waiting(_report), do: :ok

  defp open_to_answers(%{discussion_state: :closed}) do
    refuse(:reply_id, "this thread is closed")
  end

  defp open_to_answers(_report), do: :ok

  defp reply_on_this_thread(_report, nil, _actor), do: refuse(:reply_id, "names no reply")

  defp reply_on_this_thread(report, reply_id, actor) do
    case Forum.get_reply(reply_id, actor: actor) do
      {:ok, %{report_id: report_id, visibility: :published}} when report_id == report.id -> :ok
      {:ok, _reply} -> refuse(:reply_id, "is not a published reply to this thread")
      {:error, _not_found} -> refuse(:reply_id, "names no reply")
    end
  end

  defp refuse(field, message) do
    {:error, InvalidArgument.exception(field: field, message: message)}
  end
end
