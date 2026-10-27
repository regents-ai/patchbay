defmodule Patchbay.Forum.NotificationFanOutTest do
  @moduledoc """
  Each board event queues its own fan-out job when it is recorded. The job
  tells everyone following the event's site, never the person who caused it,
  and running it again tells nobody twice. An event left unfanned without a
  job, as one written just before the job existed would be, is picked up by
  the trigger's sweep.
  """

  use Patchbay.DataCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Notification
  alias Patchbay.Forum.Principal

  setup do
    site = Forum.register_site!("fan-out.example.com")
    poster = Ash.UUID.generate()

    # Follows seeded directly; following through the page is account_live_test's.
    for principal <- [Principal.for_session(poster), "session:follower"] do
      Forum.subscribe!(%{principal: principal, scope_kind: :site, scope_id: site.id},
        authorize?: false
      )
    end

    %{site: site, poster: poster}
  end

  test "a question's own job tells the site's followers once, never the poster", ctx do
    event = ask!(ctx)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :notifications)
    assert recipients(event) == ["session:follower"]

    # Lifeline can run a job again; the worker and the notifications both shrug it off.
    assert {:cancel, :trigger_no_longer_applies} =
             perform_job(ForumEvent.Workers.FanOut, %{"primary_key" => %{"id" => event.id}})

    Ash.update!(event, %{}, action: :fan_out, authorize?: false)
    assert recipients(event) == ["session:follower"]
  end

  test "an unfanned event with no job waiting is picked up by the sweep", ctx do
    event = ask!(ctx)
    Patchbay.Repo.delete_all(Oban.Job)

    assert %{failure: 0} = schedule_and_run_triggers({ForumEvent, :fan_out})
    assert recipients(event) == ["session:follower"]
    assert Ash.get!(ForumEvent, event.id, authorize?: false).fanned_out_at
  end

  defp ask!(%{site: site, poster: poster}) do
    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    report =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: poster,
          title: "Who hears about this?",
          thread_kind: :help_needed,
          body_markdown: "Asked on the board."
        },
        authorize?: false
      )

    # Events have no public way in; the test reads the one the question wrote.
    ForumEvent
    |> Ash.Query.filter(thread_id == ^report.id and kind == :thread_posted)
    |> Ash.read_one!(authorize?: false)
  end

  defp recipients(event) do
    # Every recipient's notifications, which no single reader may see.
    Notification
    |> Ash.Query.filter(event_id == ^event.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.recipient)
  end
end
