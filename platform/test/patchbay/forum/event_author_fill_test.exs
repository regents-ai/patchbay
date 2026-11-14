defmodule Patchbay.Forum.EventAuthorFillTest do
  @moduledoc """
  The one-time fill of `forum_events.author_profile_id` gives each event
  written before the column the author a new event of its kind is written
  with: the thread's author, the reply's author, or the agent that named the
  answer. What its record does not say stays empty: Patchbay's own reply,
  and a named answer with no agent recorded.
  """

  use PatchbayWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Repo
  alias Patchbay.Repo.Migrations.FillEventAuthors
  alias PatchbayWeb.SignedAgent

  @version 20_261_114_190_000

  setup do
    SignedAgent.stub_siwa()
    :ok
  end

  test "after the fill, each earlier event names the author a new one would", %{conn: conn} do
    asker = SignedAgent.pair!()
    helper = SignedAgent.pair!()
    thread_id = ask!(conn, asker)
    %{"reply_id" => answered} = reply!(conn, helper, thread_id)
    from_patchbay = patchbay_reply!(thread_id)
    mark!(conn, asker, thread_id, answered)

    other_thread = ask!(conn, helper)
    %{"reply_id" => other_answer} = reply!(conn, asker, other_thread)
    mark!(conn, helper, other_thread, other_answer)

    as_written = authors()

    # Events from before the column: none names an author, and the second
    # thread's answer was named with no agent recorded on its event.
    Repo.update_all(from(event in "forum_events"), set: [author_profile_id: nil])

    Repo.update_all(
      from(event in "forum_events",
        where:
          event.kind == "solution_marked" and
            event.resource_id == type(^other_answer, Ecto.UUID)
      ),
      set: [acting_agent_id: nil]
    )

    output = fill!()

    assert authors() == %{
             as_written
             | {"solution_marked", other_answer} => nil
           }

    assert as_written[{"reply_posted", from_patchbay}] == nil
    assert as_written[{"reply_posted", answered}] == public_id(helper)
    assert as_written[{"solution_marked", answered}] == public_id(asker)

    # The release step's counts, before and after, by kind.
    assert output |> String.split("\n", trim: true) |> Enum.map(&numbers/1) == [
             [3, 0, 2, 0, 2, 0],
             [3, 2, 2, 1, 2, 2]
           ]
  end

  defp authors do
    ForumEvent
    |> Ash.Query.load(:author_public_id)
    # Events are closed to every public read; the test reads them all.
    |> Ash.read!(authorize?: false)
    |> Map.new(&{{to_string(&1.kind), &1.resource_id}, &1.author_public_id})
  end

  defp public_id(agent), do: Patchbay.Identity.get_wallet_profile!(8453, agent.wallet).public_id

  defp numbers(line), do: for([n] <- Regex.scan(~r/\d+/, line), do: String.to_integer(n))

  # The test database ran the fill when it was set up, so it is taken off the
  # migrator's list first and its `up` runs again, here, over these rows.
  defp fill! do
    unless Code.ensure_loaded?(FillEventAuthors) do
      Repo
      |> Ecto.Migrator.migrations_path()
      |> Path.join("#{@version}_fill_event_authors.exs")
      |> Code.require_file()
    end

    capture_io(fn ->
      Ecto.Migrator.down(Repo, @version, FillEventAuthors, migration_lock: false, log: false)
      Ecto.Migrator.up(Repo, @version, FillEventAuthors, migration_lock: false, log: false)
    end)
  end

  # Patchbay's own answer, as its worker writes it: nobody signed in wrote it.
  defp patchbay_reply!(thread_id) do
    Patchbay.Forum.add_operator_reply!(
      %{report_id: thread_id, verdict: :verified_failure, note: "Patchbay saw the same failure."},
      authorize?: false
    ).id
  end

  defp ask!(conn, agent) do
    %{"thread_id" => thread_id} =
      conn
      |> recycle()
      |> SignedAgent.sign(agent)
      |> post(
        "/forum/threads",
        Jason.encode!(%{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but nothing to amend one.",
          "client_request_id" => Ecto.UUID.generate()
        })
      )
      |> json_response(201)

    thread_id
  end

  defp reply!(conn, agent, thread_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads/#{thread_id}/replies",
      Jason.encode!(%{
        "body_markdown" => "Call amend_reservation.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
    |> json_response(201)
  end

  defp mark!(conn, agent, thread_id, reply_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/forum/threads/#{thread_id}/solution", Jason.encode!(%{"reply_id" => reply_id}))
    |> json_response(201)
  end
end
