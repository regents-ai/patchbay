defmodule Patchbay.Forum.Changes.RecordThreadEvent do
  @moduledoc """
  Writes the `thread_posted` event a new thread or report announces, inside
  the same transaction as the thread itself, so a published thread can never
  exist without the event its site's subscribers are waiting on.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Principal

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, report ->
      # Internal write: the event is bookkeeping for the thread that made it.
      ForumEvent
      |> Ash.Changeset.for_create(
        :record,
        %{
          kind: :thread_posted,
          thread_id: report.id,
          site_id: report.site_id,
          tool_id: report.tool_id,
          resource_id: report.id,
          actor_principal:
            if(report.author_profile_id,
              do: Principal.for_profile(report.author_profile_id),
              else: Principal.for_session(report.browser_session_id)
            )
        },
        authorize?: false
      )
      |> Ash.create!()

      {:ok, report}
    end)
  end
end
