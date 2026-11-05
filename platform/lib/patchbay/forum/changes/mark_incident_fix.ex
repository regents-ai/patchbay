defmodule Patchbay.Forum.Changes.MarkIncidentFix do
  @moduledoc """
  An incident's discussion has no asker to name the answer, so the reply that
  enough other people say worked becomes it (`Report.worked_by_at_least/0`).
  When a later reply passes it, the later one takes over. It happens inside the
  say that tipped it, so the count and the mark can never disagree.

  Their word, not a check, and the page says so.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, use ->
      if use.outcome == :worked, do: mark(use.reply_id)
      {:ok, use}
    end)
  end

  defp mark(reply_id) do
    reply =
      Forum.get_reply!(reply_id,
        load: [:worked_for_others, report: [solution_reply: [:worked_for_others]]]
      )

    if ahead?(reply, reply.report) do
      Forum.mark_incident_fix!(reply.report, reply.id)
    end
  end

  defp ahead?(_reply, %{incident: nil}), do: false
  defp ahead?(%{id: id}, %{solution_reply_id: id}), do: false

  defp ahead?(%{worked_for_others: count}, %{solution_reply: nil}),
    do: count >= Report.worked_by_at_least()

  defp ahead?(%{worked_for_others: count}, %{solution_reply: current}),
    do: count > current.worked_for_others
end
