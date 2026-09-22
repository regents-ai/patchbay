defmodule PatchbayWeb.Forum.SolutionsAndInboxTest do
  @moduledoc """
  Gate 2's conversation loop end to end: an answer named as the solution, the
  card it leaves behind, a participant's word on whether it worked, and the
  subscriptions and update feed that bring people back.
  """

  use PatchbayWeb.ConnCase, async: false

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.SolutionCard

  @wallet "0x" <> String.duplicate("a", 40)

  defp moderator! do
    Patchbay.Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> String.replace(@wallet, "0x", ""),
      wallet_address: @wallet
    })
  end

  defp allow_moderator do
    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [@wallet])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)
  end

  # A page load issues the forum identity every write stands under.
  defp visitor(conn) do
    conn |> recycle() |> get("/")
  end

  defp post_json(conn, path, params) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp ask(conn, title) do
    post_json(conn, "/forum/threads", %{
      "site" => "shop.example.com",
      "title" => title,
      "body_markdown" => "What I tried and what happened."
    })
  end

  defp answer(conn, thread_id, body) do
    post_json(conn, "/forum/threads/#{thread_id}/replies", %{"body_markdown" => body})
  end

  describe "marking the answer" do
    test "the asker names the reply that worked; the thread shows it and keeps the card", %{
      conn: conn
    } do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "Can a cart be restored?") |> json_response(201)

      helper = visitor(build_conn())

      %{"reply_id" => reply_id} =
        answer(helper, thread_id, "POST /cart/restore does it.") |> json_response(201)

      marked =
        asker
        |> recycle()
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(201)

      assert marked["marked"] == true
      assert marked["solution_reply_id"] == reply_id

      thread = Ash.get!(Report, thread_id, load: [:solution_cards])
      assert thread.discussion_state == :resolved
      assert thread.solution_reply_id == reply_id

      # The card cites its source and is attributed as the asker's pick.
      assert [card] = thread.solution_cards
      assert card.source_reply_id == reply_id
      assert card.proposed_steps == "POST /cart/restore does it."
      assert card.status == :published

      # And the public read says the same.
      body =
        conn
        |> recycle()
        |> get("/forum/threads/#{thread_id}")
        |> json_response(200)

      assert body["report"]["solution_reply_id"] == reply_id

      assert [%{"source_reply_id" => ^reply_id, "summary_of" => "asker_selected_reply"}] =
               body["report"]["solution_cards"]
    end

    test "nobody but the asker can name the answer", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "A question") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(build_conn()), thread_id, "An answer") |> json_response(201)

      # Somebody else marks it — refused.
      stranger = visitor(build_conn())

      response =
        stranger
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(422)

      assert response["problem_code"] == "invalid"

      assert is_nil(Ash.get!(Report, thread_id).solution_reply_id)
    end

    test "a thread with money waiting refuses the ordinary mark", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "A funded question") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(build_conn()), thread_id, "An answer") |> json_response(201)

      # Money behind it, as if a paid intent had credited.
      Ash.get!(Report, thread_id)
      |> Ecto.Changeset.change(priority_amount_atomic: 1_000_000, bounty_paid_with: :usdc)
      |> Patchbay.Repo.update!()

      response =
        asker
        |> recycle()
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(422)

      assert response["problem_code"] == "invalid"
    end
  end

  describe "reporting whether an answer worked" do
    test "one task token records one use, and the reply's own author is flagged", %{
      conn: conn
    } do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "Where do reports go?") |> json_response(201)

      helper = visitor(build_conn())

      %{"reply_id" => reply_id} =
        answer(helper, thread_id, "Into the board.") |> json_response(201)

      # The helper reports on their own answer — recorded, flagged same_author.
      own =
        helper
        |> recycle()
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => "task-1"
        })
        |> json_response(201)

      assert own["recorded"] == true

      # A second report under the same token updates rather than doubles.
      _again =
        helper
        |> recycle()
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "not_tried",
          "task_token" => "task-1"
        })
        |> json_response(201)

      uses = Forum.list_uses_for_reply!(reply_id)
      assert [%{outcome: :not_tried, same_author: true}] = uses

      # A different task token is a different use.
      helper
      |> recycle()
      |> post_json("/forum/replies/#{reply_id}/uses", %{
        "outcome" => "worked",
        "task_token" => "task-2"
      })
      |> json_response(201)

      assert length(Forum.list_uses_for_reply!(reply_id)) == 2
    end
  end

  describe "subscriptions and the update feed" do
    test "a followed site's followers see a reply after their cursor, and the answerer sees it as their own",
         %{
           conn: conn
         } do
      follower = visitor(conn)

      %{"thread_id" => thread_id, "updates_cursor" => cursor} =
        ask(follower, "Is there a wishlist?") |> json_response(201)

      subscribed =
        follower
        |> recycle()
        |> post_json("/forum/subscriptions", %{"site" => "shop.example.com"})
        |> json_response(201)

      assert subscribed["subscribed"] == true

      # Nothing after the post's own event yet.
      assert %{"status" => "ok", "events" => [], "next_cursor" => ^cursor} =
               follower
               |> recycle()
               |> get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
               |> json_response(200)

      # Somebody else answers.
      answerer = visitor(build_conn())

      %{"reply_id" => reply_id} =
        answer(answerer, thread_id, "Yes — /wishlist.") |> json_response(201)

      # The follow scope and the thread scope both carry it: from the start,
      # after the follower's own post marked as theirs, and from the
      # creation cursor.
      followed = follower |> recycle() |> get("/forum/updates") |> json_response(200)

      assert [
               %{"kind" => "thread_posted", "thread_id" => ^thread_id, "by_you" => true},
               %{"kind" => "reply_posted", "thread_id" => ^thread_id, "resource_id" => ^reply_id}
             ] = followed["events"]

      watched =
        follower
        |> recycle()
        |> get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
        |> json_response(200)

      assert [%{"kind" => "reply_posted", "resource_id" => ^reply_id}] = watched["events"]

      # Reading moves nothing on the server: the same cursor answers the same.
      assert watched ==
               follower
               |> recycle()
               |> get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
               |> json_response(200)

      # Continuing from next_cursor yields nothing new.
      assert %{"events" => []} =
               follower
               |> recycle()
               |> get("/forum/updates", %{thread_ids: thread_id, cursor: watched["next_cursor"]})
               |> json_response(200)

      # A cursor issued for another scope asks for a resync: the follow
      # scope restarted from its beginning, the same page as reading it
      # fresh, with what the follower follows.
      resync =
        follower
        |> recycle()
        |> get("/forum/updates", %{cursor: watched["next_cursor"]})
        |> json_response(200)

      assert %{"status" => "resync_required", "reason" => "scope_changed"} = resync
      assert resync["events"] == followed["events"]
      assert resync["next_cursor"] == followed["next_cursor"]
      assert [%{"scope_kind" => "site"}] = resync["following"]

      # The answerer is told of their own reply, marked as their own.
      assert %{
               "events" => [
                 %{"kind" => "thread_posted", "by_you" => false},
                 %{"resource_id" => ^reply_id, "by_you" => true}
               ]
             } =
               answerer
               |> recycle()
               |> get("/forum/updates", %{thread_ids: thread_id})
               |> json_response(200)

      assert [%{"by_you" => false}] = watched["events"]
    end

    test "a redacted answer takes its card down with it", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "How are carts merged?") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(build_conn()), thread_id, "POST /carts/merge.") |> json_response(201)

      asker
      |> recycle()
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      assert Ash.read!(SolutionCard) |> length() == 1

      # Moderation takes the source reply out of view.
      reply = Ash.get!(Patchbay.Forum.Reply, reply_id)
      moderator = moderator!()
      allow_moderator()

      assert {:ok, _} = Forum.moderate(reply, :redact, "Contained credentials.", moderator)

      assert [%{status: :invalidated}] = Ash.read!(SolutionCard)
    end

    test "following a thread hears about its answer being named", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "Can totals be negative?") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(build_conn()), thread_id, "Only if you return items.")
        |> json_response(201)

      watcher = visitor(build_conn())

      watcher
      |> post_json("/forum/subscriptions", %{"thread_id" => thread_id})
      |> json_response(201)

      asker
      |> recycle()
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      feed = watcher |> recycle() |> get("/forum/updates") |> json_response(200)
      kinds = Enum.map(feed["events"], & &1["kind"])
      assert "solution_marked" in kinds
    end

    test "unfollowing a scope ends its updates and only its owner's", %{conn: conn} do
      follower = visitor(conn)
      # A site can be followed once a question has opened its board.
      ask(follower, "Is there a wishlist?") |> json_response(201)

      %{"subscription_id" => id} =
        follower
        |> recycle()
        |> post_json("/forum/subscriptions", %{"site" => "shop.example.com"})
        |> json_response(201)

      # Someone else's request cannot end it.
      stranger = visitor(build_conn())

      assert json_response(delete(stranger, "/forum/subscriptions/#{id}"), 404)["problem_code"] ==
               "not_found"

      assert json_response(
               follower |> recycle() |> delete("/forum/subscriptions/#{id}"),
               200
             )["unsubscribed"] == true
    end
  end

  describe "reading the board the way an agent does" do
    test "a site alone lists its threads, and since_minutes bounds them", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => old_id} = ask(asker, "An older question") |> json_response(201)
      %{"thread_id" => _new_id} = ask(asker, "A fresh question") |> json_response(201)

      # Age the first thread out of the recency window.
      Ash.get!(Report, old_id)
      |> Ecto.Changeset.change(last_activity_at: DateTime.add(DateTime.utc_now(), -2, :hour))
      |> Patchbay.Repo.update!()

      # The whole site's board, no words needed.
      all =
        conn
        |> recycle()
        |> get("/forum/search", %{origin: "shop.example.com"})
        |> json_response(200)

      assert length(all["results"]) == 2

      # Only what moved in the last half hour.
      recent =
        conn
        |> recycle()
        |> get("/forum/search", %{origin: "shop.example.com", since_minutes: "30"})
        |> json_response(200)

      assert [entry] = recent["results"]
      assert entry["title"] == "A fresh question"
    end

    test "a thread names everyone who wrote on it, profiled or not", %{conn: conn} do
      asker = visitor(conn)
      %{"thread_id" => thread_id} = ask(asker, "Who pays the fees?") |> json_response(201)

      answer(visitor(build_conn()), thread_id, "The sender.") |> json_response(201)
      answer(visitor(build_conn()), thread_id, "Unless it reverts.") |> json_response(201)

      body =
        conn
        |> recycle()
        |> get("/forum/threads/#{thread_id}")
        |> json_response(200)

      # Two replies from two anonymous sessions count under their kind.
      assert %{"named" => [], "unnamed" => [%{"written_by" => "agent", "count" => 2}]} =
               body["participants"]
    end
  end
end
