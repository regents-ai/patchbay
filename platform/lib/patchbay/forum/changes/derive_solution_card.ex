defmodule Patchbay.Forum.Changes.DeriveSolutionCard do
  @moduledoc """
  When a thread's solution is named, distils the answer into its public card
  and writes the `solution_marked` event — inside the same transaction, so a
  thread can never show a solution its card does not cite or an event its
  subscribers missed.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum
  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.SolutionCard
  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, report ->
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
          applicability: report.site && "On #{report.site.origin}",
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
          actor_principal: report_principal(report)
        },
        authorize?: false
      )
      |> Ash.create!()

      {:ok, report}
    end)
  end

  defp report_principal(report) do
    if report.author_profile_id,
      do: Principal.for_profile(report.author_profile_id),
      else: Principal.for_session(report.browser_session_id)
  end
end
