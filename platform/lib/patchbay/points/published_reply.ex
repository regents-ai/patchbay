defmodule Patchbay.Points.PublishedReply do
  @moduledoc """
  Regent Points' check of a reply (`patchbay.reply_published`): it reads the
  saved reply and answers with what Points records. Points asks when it
  records the reply and again when it awards it, so the check only reads this
  site's own saved records and changes nothing. Every reply passed Patchbay's
  posting check before it was published (`Patchbay.Forum.PostingCheck`); on top
  of that a reply earns only:

    * while it and its thread are shown and moderation has not set the reply
      aside;
    * for the person who wrote it, or whose agent did (`Patchbay.Points.Writer`);
    * on a thread a different person started: never a reply on one's own
      thread or one's own agents' threads, nor on a thread no person started.
  """

  alias Patchbay.Forum
  alias Patchbay.Points.PublishedReport
  alias Patchbay.Points.Writer

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' server check reads the committed reply it was given.
    case Forum.get_reply(id, load: [:report], not_found_error?: false) do
      {:ok, nil} ->
        {:error, :reply_not_found}

      {:ok, reply} ->
        with :ok <- earns(reply),
             {:ok, writer} <- Writer.of(reply),
             do: {:ok, facts(reply, writer)}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  @doc "Whether moderation leaves a reply able to earn: shown, and not set aside."
  def shown?(reply),
    do:
      reply.visibility == :published and
        reply.reward_eligibility not in [:ineligible_spam, :removed]

  defp earns(%{report: report} = reply) do
    cond do
      not shown?(reply) -> {:error, :reply_not_shown}
      not PublishedReport.shown?(report) -> {:error, :thread_not_shown}
      is_nil(report.privy_user_id) -> {:error, :thread_not_by_a_person}
      report.privy_user_id == reply.privy_user_id -> {:error, :own_thread}
      true -> :ok
    end
  end

  defp facts(reply, writer) do
    %{
      source_app: "patchbay",
      source_kind: "reply",
      source_event_key: reply.id,
      account_id: writer.account_id,
      actor_kind: writer.actor_kind,
      actor_id: writer.actor_id,
      source_action_at: reply.inserted_at,
      qualified_at: reply.inserted_at,
      evidence_ref: "reply:" <> reply.id,
      evidence: Map.put(writer.evidence, "report_id", reply.report_id)
    }
  end
end
