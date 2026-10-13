defmodule PatchbayWeb.Forum.PostReviewTest do
  # The moderators' page for posts turned away before they were published.
  # These run alone: they share the day's count of posts turned away.
  use PatchbayWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Patchbay.Forum
  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.PostCheck
  alias Patchbay.Forum.PostCheckPruner
  alias Patchbay.JevStandIn
  alias Patchbay.Repo
  alias PatchbayWeb.SignedAgent

  @wallet "0x" <> String.duplicate("c", 40)

  setup do
    SignedAgent.stub_siwa()

    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [@wallet])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)

    moderator =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:" <> String.replace(@wallet, "0x", ""),
        wallet_address: @wallet
      })

    %{agent: SignedAgent.pair!(), moderator: moderator}
  end

  test "a post turned away is listed for a moderator with the words that were refused",
       %{conn: conn, agent: agent, moderator: moderator} do
    JevStandIn.finds("spam", 0.95)
    assert conn |> ask(agent, "Buy followers today") |> json_response(422)

    page = page(conn, moderator)

    assert page =~ "Turned away"
    assert page =~ "Buy followers today"
    assert page =~ "spam"
    assert page =~ "95% sure"
    assert page =~ "sent by their agent"
    # Nothing was published.
    assert Ash.read!(Patchbay.Forum.Report, authorize?: false) == []
  end

  test "a post ruled wrong to block stops counting, so the pause it caused ends, and the ruling is on record",
       %{conn: conn, agent: agent, moderator: moderator} do
    JevStandIn.finds("fake", 0.9)
    for title <- ~w(one two three), do: assert(conn |> ask(agent, title) |> json_response(422))

    JevStandIn.accept_posts()
    assert conn |> ask(agent, "Does export work?") |> json_response(403)

    [_first, _second, third] = checks()

    assert conn |> decide(moderator, "post", third.id, "wrong") |> redirected_to() ==
             ~p"/moderation"

    assert conn |> ask(agent, "Does export work?") |> json_response(201)
    assert page(conn, moderator) =~ "Ruled wrong to block."

    assert [
             %{
               action: :wrong_to_block,
               subject_kind: :post_check,
               subject_id: id,
               actor_profile_id: by
             }
           ] =
             decisions()

    assert id == third.id
    assert by == moderator.id

    # A press that names something that was not turned away changes nothing.
    assert conn |> decide(moderator, "post", Ash.UUID.generate(), "right") |> redirected_to() ==
             ~p"/moderation"

    assert length(decisions()) == 1
  end

  test "lifting a pause lets the person post again from none, and is on record",
       %{conn: conn, agent: agent, moderator: moderator} do
    JevStandIn.finds("too_short", 0.9)
    for title <- ~w(one two three), do: assert(conn |> ask(agent, title) |> json_response(422))

    assert page(conn, moderator) =~ "Lift pause"
    assert conn |> decide(moderator, "person", agent.owner.id, "lift") |> redirected_to()

    # The next post turned away is the first of three again.
    refused = conn |> ask(agent, "four") |> json_response(422)
    assert %{"rejects_today" => 1, "posting_paused_until" => nil} = refused["error"]

    assert [%{action: :pause_lifted, subject_kind: :person, subject_id: person}] = decisions()
    assert person == agent.owner.id
    refute page(conn, moderator) =~ "Lift pause"
  end

  test "a ruling alone shows Jev nothing; an example is a press of its own, and Jev is sent exactly the cut the page showed",
       %{conn: conn, agent: agent, moderator: moderator} do
    long = String.duplicate("Follow my page for cheap followers. ", 30)

    JevStandIn.finds("spam", 0.95)
    assert conn |> ask(agent, "Buy followers today", long) |> json_response(422)
    [check] = checks()
    other = SignedAgent.pair!()
    JevStandIn.accept_posts()

    assert conn |> decide(moderator, "post", check.id, "right") |> redirected_to()
    assert conn |> ask(other, "Does export work?") |> json_response(201)
    refute Map.has_key?(last_shown(), "examples")

    cut = String.slice("Buy followers today\n" <> String.trim(long), 0, 400)
    assert String.length(cut) == 400
    assert page(conn, moderator) =~ "Use as an example"
    assert page(conn, moderator) =~ String.slice(cut, 20, 100)

    assert conn |> decide(moderator, "post", check.id, "example") |> redirected_to()
    assert conn |> ask(other, "Does import work?") |> json_response(201)
    assert %{"examples" => [%{"finding" => "spam", "words" => ^cut}]} = last_shown()

    # A ruling that changes takes its example out with it.
    assert conn |> decide(moderator, "post", check.id, "wrong") |> redirected_to()
    assert conn |> ask(other, "Does print work?") |> json_response(201)
    refute Map.has_key?(last_shown(), "examples")

    # And a moderator can take one out by itself.
    assert conn |> decide(moderator, "post", check.id, "example") |> redirected_to()
    assert conn |> ask(other, "Does search work?") |> json_response(201)
    assert %{"examples" => [%{"finding" => "acceptable", "words" => ^cut}]} = last_shown()
    assert conn |> decide(moderator, "post", check.id, "no_example") |> redirected_to()
    assert conn |> ask(other, "Does sort work?") |> json_response(201)
    refute Map.has_key?(last_shown(), "examples")

    assert Enum.map(decisions(), & &1.action) == [
             :right_to_block,
             :example_added,
             :wrong_to_block,
             :example_added,
             :example_removed
           ]
  end

  test "past the day's count of kept words a post turned away keeps its digest and no words",
       %{conn: conn, agent: agent} do
    kept =
      for _each <- 1..500 do
        %{
          profile_id: Ash.UUID.generate(),
          kind: :reply,
          finding: :spam,
          confidence: 0.9,
          rejected: true,
          model: "jev-stand-in",
          input_sha256: String.duplicate("0", 64),
          shown: %{"kind" => "a reply on a thread", "body" => "Buy followers"}
        }
      end

    # Seeded as Patchbay's own records.
    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(kept, PostCheck, :record, authorize?: false)

    test = self()

    :telemetry.attach(
      "post-review-test",
      [:patchbay, :post_readings, :words_not_kept],
      fn _event, counts, _meta, _config -> send(test, {:words_not_kept, counts}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("post-review-test") end)

    JevStandIn.finds("spam", 0.95)
    assert conn |> ask(agent, "Buy followers today") |> json_response(422)

    assert [%{shown: nil, input_sha256: digest}] =
             Enum.filter(checks(), &(&1.profile_id == agent.owner.id))

    assert byte_size(digest) == 64
    assert_received {:words_not_kept, %{count: 500, ceiling: 500}}
  end

  test "the daily clean-up forgets words a month old and keeps the reading, its ruling and its example",
       %{conn: conn, agent: agent, moderator: moderator} do
    JevStandIn.finds("spam", 0.95)
    assert conn |> ask(agent, "Buy followers today") |> json_response(422)
    assert conn |> ask(agent, "Buy more followers today") |> json_response(422)
    [old, recent] = checks()

    assert conn |> decide(moderator, "post", old.id, "right") |> redirected_to()
    assert conn |> decide(moderator, "post", old.id, "example") |> redirected_to()

    month_ago = DateTime.add(DateTime.utc_now(), -(PostCheckPruner.kept_days() + 1), :day)

    Repo.update_all(from(check in PostCheck, where: check.id == ^old.id),
      set: [inserted_at: month_ago]
    )

    assert :ok = PostCheckPruner.perform(%Oban.Job{})

    assert %{shown: nil, ruling: :right, example: "Buy followers today" <> _rest, rejected: true} =
             Forum.get_post_check!(old.id, authorize?: false)

    assert %{shown: %{"title" => "Buy more followers today"}} =
             Forum.get_post_check!(recent.id, authorize?: false)

    assert page(conn, moderator) =~ "Its words are no longer kept."
  end

  defp ask(conn, agent, title, body \\ "I called export_orders and it returned an empty file.") do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads",
      Jason.encode!(%{
        "site" => "reviewed.example.net",
        "title" => title,
        "body_markdown" => body,
        "client_request_id" => Ecto.UUID.generate()
      })
    )
  end

  defp signed_in(conn, moderator) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(moderator.id)
  end

  defp page(conn, moderator),
    do: conn |> signed_in(moderator) |> get(~p"/moderation") |> html_response(200)

  defp decide(conn, moderator, kind, id, action) do
    conn
    |> signed_in(moderator)
    |> post(~p"/moderation", %{"subject" => %{"kind" => kind, "id" => id, "action" => action}})
  end

  # What Jev was shown for the newest post, with the earlier ones set aside.
  defp last_shown do
    receive do
      {:jev_was_shown, shown} -> newest(shown)
    after
      0 -> flunk("Jev was not asked")
    end
  end

  defp newest(shown) do
    receive do
      {:jev_was_shown, later} -> newest(later)
    after
      0 -> shown
    end
  end

  # Reads back the test's own records, oldest first.
  defp checks,
    do: PostCheck |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.inserted_at, DateTime)

  # The same.
  defp decisions,
    do:
      ModerationAction |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.inserted_at, DateTime)
end
