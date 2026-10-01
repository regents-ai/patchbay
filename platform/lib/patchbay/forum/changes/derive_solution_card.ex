defmodule Patchbay.Forum.Changes.DeriveSolutionCard do
  @moduledoc """
  When a thread's solution is named, distils the answer into its public card
  and writes the `solution_marked` event — inside the same transaction, so a
  thread can never show a solution its card does not cite or an event its
  subscribers missed.

  Naming the reply that is already the solution changes nothing: no second
  card, no second event. Naming a different reply retires the card the old
  one stood behind, so a thread shows one card, for the answer it names now.
  The comparison is made against the row as the action's lock reads it
  (`get_and_lock_for_update/0` runs first), so two marks racing each other
  see one another.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.SolutionCard
  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.put_context(changeset, :solution_before, changeset.data.solution_reply_id)
    end)
    |> Ash.Changeset.after_action(fn changeset, report ->
      case changeset.context.solution_before do
        same when same == report.solution_reply_id ->
          {:ok, report}

        before ->
          retire_card(report.id, before)
          derive(report)
          {:ok, report}
      end
    end)
  end

  defp retire_card(_thread_id, nil), do: :ok

  defp retire_card(thread_id, reply_id) do
    # Internal write: the asker has named a different answer.
    SolutionCard
    |> Ash.Query.filter(thread_id == ^thread_id and source_reply_id == ^reply_id)
    |> Ash.bulk_update!(:invalidate, %{}, authorize?: false)
  end

  defp derive(report) do
    report = Ash.load!(report, [:site])
    reply = Forum.get_reply!(report.solution_reply_id)

    body = reply.body_markdown || reply.note || ""

    # Internal write: the card stands because the asker named the answer.
    SolutionCard
    |> Ash.Changeset.for_create(
      :derive,
      %{
        thread_id: report.id,
        source_reply_id: reply.id,
        problem_summary: String.slice(report.title || report.note || "A thread", 0, 500),
        applicability: "On #{report.site.origin}",
        proposed_steps: String.slice(body, 0, 4_096),
        source_digest: Digest.sha256(body),
        source_author_profile_id: reply.author_profile_id,
        reviewed_by_profile_id: report.author_profile_id
      },
      authorize?: false
    )
    |> Ash.create!()

    ForumEvent
    |> Ash.Changeset.for_create(
      :record,
      %{
        kind: :solution_marked,
        thread_id: report.id,
        site_id: report.site_id,
        tool_id: report.tool_id,
        resource_id: reply.id,
        actor_principal: Principal.for(report)
      },
      authorize?: false
    )
    |> Ash.create!()
  end
end
