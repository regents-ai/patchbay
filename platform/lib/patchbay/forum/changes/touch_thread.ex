defmodule Patchbay.Forum.Changes.TouchThread do
  @moduledoc """
  Marks the thread a reply landed on as moved: `last_activity_at` becomes now,
  and only the thread the reply actually belongs to moves. Its discussion
  state follows from its replies on its own.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Forum.Report

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, reply ->
      # Internal bookkeeping on the reply's own thread; `touch` names no
      # policy because nothing over HTTP may call it.
      thread =
        Report
        |> Ash.Query.filter(id == ^reply.report_id)
        |> Ash.read_one!(authorize?: false)

      Report
      |> Ash.Query.filter(id == ^reply.report_id)
      |> Ash.bulk_update!(:touch, %{}, authorize?: false)

      # The reply and its event commit together, so a written reply can never
      # exist without the event a subscriber is waiting on.
      Patchbay.Forum.ForumEvent
      |> Ash.Changeset.for_create(
        :record,
        %{
          kind: :reply_posted,
          thread_id: reply.report_id,
          site_id: thread && thread.site_id,
          tool_id: thread && thread.tool_id,
          resource_id: reply.id,
          actor_principal: Patchbay.Forum.Principal.for(reply)
        }
        |> Map.merge(
          Map.take(reply, [
            :acting_agent_id,
            :beneficiary_profile_id,
            :human_account_id,
            :pairing_id
          ])
        ),
        authorize?: false
      )
      |> Ash.create!()

      {:ok, reply}
    end)
  end
end
