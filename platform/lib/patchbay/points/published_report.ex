defmodule Patchbay.Points.PublishedReport do
  @moduledoc """
  Regent Points' check of a thread (`patchbay.report_published`): it reads the
  saved thread and its replies and answers with what Points records. Points
  asks when it records the thread and again when it awards it, so the check
  only reads this site's own saved records and changes nothing. Every thread
  passed Patchbay's posting check before it was published
  (`Patchbay.Forum.PostingCheck`); on top of that a thread earns only:

    * while it is shown;
    * for the person who started it, or whose agent did
      (`Patchbay.Points.Writer`);
    * once a different person, or that person's agent, has replied, with a
      reply that is shown and that moderation has not set aside. Points records
      the thread as posted when it was posted, and earned when that first reply
      came. A reply from no person, or from the same person or their agents,
      does not count.
  """

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Reply
  alias Patchbay.Points.Writer

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' server check reads the committed thread it was given.
    case Forum.get_report(id, not_found_error?: false) do
      {:ok, nil} -> {:error, :report_not_found}
      {:ok, report} -> earns(report)
      {:error, reason} -> {:retry, reason}
    end
  end

  @doc "Whether moderation leaves a thread able to earn: shown."
  def shown?(report), do: report.visibility == :published

  defp earns(report) do
    with :ok <- if(shown?(report), do: :ok, else: {:error, :report_not_shown}),
         {:ok, writer} <- Writer.of(report),
         {:ok, reply} <- first_reply_from_another_person(report),
         do: {:ok, facts(report, reply, writer)}
  end

  # The first reply that makes the thread earn, as `Patchbay.Points.PublishedReply`
  # reads a reply: shown, not set aside, and by a person other than the asker.
  defp first_reply_from_another_person(report) do
    Reply
    |> Ash.Query.filter(
      report_id == ^report.id and visibility == :published and
        reward_eligibility not in [:ineligible_spam, :removed] and
        not is_nil(privy_user_id) and privy_user_id != ^report.privy_user_id
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :no_reply_from_another_person}
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp facts(report, reply, writer) do
    %{
      source_app: "patchbay",
      source_kind: "report",
      source_event_key: report.id,
      account_id: writer.account_id,
      actor_kind: writer.actor_kind,
      actor_id: writer.actor_id,
      source_action_at: report.inserted_at,
      qualified_at: reply.inserted_at,
      evidence_ref: "report:" <> report.id,
      evidence: Map.put(writer.evidence, "reply_id", reply.id)
    }
  end
end
