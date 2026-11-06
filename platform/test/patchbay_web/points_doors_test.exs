defmodule PatchbayWeb.PointsDoorsTest do
  @moduledoc """
  What Patchbay offers Regent Points. Every door that publishes a report or
  reply lets Jev read it first (`Patchbay.Forum.PostingCheck`), so a post Jev
  turns away is never written and offers Points nothing, and a post it lets
  through offers Points its check in the same transaction. Points then
  credits the person who posted, or the person whose agent did, and takes it
  back when a moderator hides the post. An Offer earns when its bid starts
  showing. Earning is set in the application's `:regent_points` settings and
  Jev's count of posts turned away is shared, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  require Ash.Query
  require Ecto.Query

  import Patchbay.OffersFixtures,
    only: [approved_version: 3, bid: 5, give_credits: 2, moderator: 0, settle: 2]

  alias Patchbay.Forum
  alias Patchbay.JevStandIn
  alias Patchbay.Offers
  alias Patchbay.Payments.SpecialPost
  alias Patchbay.Points
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent
  alias RegentPayments.PaymentIntent

  @rules ~w(patchbay.report_published patchbay.reply_published)
  @system %{role: :system}

  setup %{conn: conn} do
    SignedAgent.stub_siwa()
    earn_on(["patchbay.offer_bid_placed" | @rules])
    agent = SignedAgent.pair!()

    %{
      agent: agent,
      person: conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(agent.owner.id)
    }
  end

  describe "an agent" do
    test "asking a question", %{conn: conn, agent: agent} do
      thread = fn -> send_json(conn, agent, "/forum/threads", question()) end

      turned_away(thread, "report")
      assert %{"thread_id" => id} = thread.() |> json_response(201)
      assert_offered("report", id)
    end

    test "replying on a thread", %{conn: conn, agent: agent} do
      %{"thread_id" => thread_id} =
        conn |> send_json(agent, "/forum/threads", question()) |> json_response(201)

      reply = fn ->
        send_json(conn, agent, "/forum/threads/#{thread_id}/replies", %{
          "body_markdown" => "Export worked once I picked the date range first."
        })
      end

      turned_away(reply, "reply")
      assert %{"reply_id" => id} = reply.() |> json_response(201)
      assert_offered("reply", id)
    end

    test "reporting a tool call", %{conn: conn, agent: agent} do
      report = fn -> send_json(conn, agent, "/forum/reports", tool_report()) end

      turned_away(report, "report")
      assert %{"report_id" => id} = report.() |> json_response(201)
      assert_offered("report", id)
    end

    test "saying whether a reported tool worked", %{conn: conn, agent: agent} do
      %{"report_id" => report_id} =
        conn |> send_json(agent, "/forum/reports", tool_report()) |> json_response(201)

      reply = fn ->
        send_json(conn, agent, "/forum/reports/#{report_id}/replies", %{
          "verdict" => "verified_success",
          "note" => "It added the item once the size was chosen first."
        })
      end

      turned_away(reply, "reply")
      assert %{"reply_id" => id} = reply.() |> json_response(201)
      assert_offered("reply", id)
    end
  end

  describe "a person" do
    test "asking a question", %{person: person} do
      typed = %{
        "goal" => "Where does a declined card go?",
        "site_url" => "checkout.example/cart",
        "details" => "I tried twice and the cart stayed empty after the card was declined."
      }

      preview = person |> post(~p"/threads", %{"ask" => typed, "step" => "preview"})
      [_, digest] = Regex.run(~r/name="previewed" value="([^"]+)"/, html_response(preview, 200))

      ask = fn ->
        post(person, ~p"/threads", %{"ask" => typed, "step" => "post", "previewed" => digest})
      end

      turned_away(ask, "report")
      [_, id] = Regex.run(~r{/posts/([^/]+)/}, redirected_to(ask.()))
      assert_offered("report", id)
    end

    test "replying on a thread", %{conn: conn, agent: agent, person: person} do
      %{"thread_id" => thread_id} =
        conn |> send_json(agent, "/forum/threads", question()) |> json_response(201)

      reply = fn ->
        post(person, ~p"/threads/#{thread_id}/replies", %{
          "reply" => %{"body_markdown" => "Export worked once I picked the date range first."}
        })
      end

      turned_away(reply, "reply")
      assert redirected_to(reply.())
      assert_offered("reply", only_reply(thread_id).id)
    end

    test "saying whether a reported tool worked", %{conn: conn, agent: agent, person: person} do
      %{"report_id" => report_id} =
        conn |> send_json(agent, "/forum/reports", tool_report()) |> json_response(201)

      reply = fn ->
        post(person, ~p"/reports/#{report_id}/replies", %{
          "reply" => %{
            "verdict" => "verified_failure",
            "note" => "The cart stayed empty for me as well."
          }
        })
      end

      turned_away(reply, "reply")
      assert redirected_to(reply.())
      assert_offered("reply", only_reply(report_id).id)
    end

    # A paid priority report is read when it is priced, then published as its
    # intent froze it once the payment settles, so one Jev turns away is
    # never priced.
    test "paying for a priority report", %{person: person, agent: agent} do
      escrow = Application.get_env(:patchbay, :escrow)
      Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("c", 40))
      on_exit(fn -> Application.put_env(:patchbay, :escrow, escrow) end)

      price = fn ->
        post(person, "/api/payment_intents", %{
          "kind" => "special_post",
          "args" => Map.merge(Map.delete(tool_report(), "arguments"), %{"amount_usdc" => "1"})
        })
      end

      turned_away(price, "report")
      assert PaymentIntent |> Ash.read!(authorize?: false) == []

      assert price.() |> json_response(201)
      intent = PaymentIntent |> Ash.read_one!(authorize?: false)
      refute_enqueued(worker: RegentPoints.IntakeWorker)

      assert {:ok, :complete} =
               SpecialPost.carry_out(intent, nil, agent.owner, %{
                 browser_session_id: Ecto.UUID.generate()
               })

      assert_offered("report", intent.payload["report_id"])
    end
  end

  describe "what Points credits" do
    test "an agent's report earns for the person it is paired with, under the agent's wallet",
         %{conn: conn, agent: agent} do
      %{"report_id" => id} =
        conn |> send_json(agent, "/forum/reports", tool_report()) |> json_response(201)

      award()

      assert [
               %{
                 rule_id: "patchbay.report_published",
                 processing_status: :confirmed,
                 account_id: account_id,
                 actor_kind: "agent",
                 actor_id: wallet,
                 evidence: %{"attribution_link_id" => pairing_id}
               }
             ] = events("report", id)

      assert account_id == agent.account.id
      assert wallet == agent.pairing.wallet
      assert pairing_id == agent.pairing.id

      # The Points page names the agent by the wallet it earned under.
      assert Points.Accounts.agent_names(agent.account.id, [agent.pairing.wallet]) ==
               {:ok, %{agent.pairing.wallet => agent.pairing.name}}
    end

    test "a person's reply earns for them", %{conn: conn, agent: agent, person: person} do
      %{"thread_id" => thread_id} =
        conn |> send_json(agent, "/forum/threads", question()) |> json_response(201)

      post(person, ~p"/threads/#{thread_id}/replies", %{
        "reply" => %{"body_markdown" => "Export worked once I picked the date range first."}
      })

      id = only_reply(thread_id).id
      award()

      assert [event] = events("reply", id)
      assert %{processing_status: :confirmed, actor_kind: "human"} = event
      assert event.account_id == agent.account.id
      assert event.actor_id == to_string(agent.account.id)
    end

    test "an agent earns nothing for a person it is not paired with", %{agent: agent} do
      assert Points.Beneficiary.of(agent.owner.privy_user_id, Ecto.UUID.generate()) ==
               {:error, :agent_not_paired_with_person}
    end

    test "a post hidden before Points checks it earns nothing", %{conn: conn, agent: agent} do
      %{"report_id" => id} =
        conn |> send_json(agent, "/forum/reports", tool_report()) |> json_response(201)

      {:ok, _hidden} = Forum.moderate(report(id), :quarantine, "Spam link.", moderator())
      award()

      assert events("report", id) == []
      assert entries("report", id) == []
    end

    test "a bid earns once it starts showing, and a bid that is outbid earns nothing",
         %{agent: agent} do
      market = Offers.global_market!()
      give_credits(agent.owner, "10")
      winner = approved_version(agent.owner, "Alice fixes flaky builds.", market)
      loser = approved_version(agent.owner, "Alice ships faster deploys.", market)

      {:ok, outbid} = bid(agent.owner, market, 1, loser, "2.00")
      {:ok, placed} = bid(agent.owner, market, 1, winner, "3.00")
      refute_enqueued(worker: RegentPoints.IntakeWorker, args: %{"source_kind" => "offer_bid"})

      settle(market, 1)

      assert [%{args: %{"source_event_key" => key}}] =
               all_enqueued(
                 worker: RegentPoints.IntakeWorker,
                 args: %{"source_kind" => "offer_bid"}
               )

      assert key == placed.id

      assert Points.OfferBid.verify(%{"source_event_key" => outbid.id}) ==
               {:error, :bid_not_placed}

      award()

      assert [%{processing_status: :confirmed, actor_kind: "human"} = event] =
               events("offer_bid", placed.id)

      assert event.account_id == agent.account.id
    end
  end

  describe "a post hidden after it earned" do
    setup %{conn: conn, agent: agent} do
      %{"report_id" => id} =
        conn |> send_json(agent, "/forum/reports", tool_report()) |> json_response(201)

      award()
      assert [_] = earned = entries("report", id)
      %{id: id, earned: earned}
    end

    test "gives back what it earned, once", %{id: id, earned: earned} do
      moderator = moderator()
      {:ok, hidden} = Forum.moderate(report(id), :quarantine, "Spam link.", moderator)
      {:ok, _redacted} = Forum.moderate(hidden, :redact, "Spam link.", moderator)

      assert [_one] = all_enqueued(worker: Points.Correction, args: %{kind: "report", id: id})
      award()
      assert :ok = perform_job(Points.Correction, %{kind: "report", id: id})

      given_back = entries("report", id) -- earned

      assert Enum.map(given_back, & &1.reversal_of_entry_id) |> Enum.sort() ==
               Enum.map(earned, & &1.id) |> Enum.sort()

      for entry <- given_back do
        award = Enum.find(earned, &(&1.id == entry.reversal_of_entry_id))
        assert entry.points_micro_delta == -award.points_micro_delta
      end
    end

    # Points may be checking the post for another of its rules, having read it
    # before the moderator's word, so nothing is given back until it is done.
    test "waits while Points is still checking the post", %{id: id, earned: earned} do
      {:ok, _hidden} = Forum.moderate(report(id), :quarantine, "Spam link.", moderator())

      checking =
        Oban.insert!(
          RegentPoints.IntakeWorker.new(%{
            rule_id: "patchbay.report_published",
            source_app: "patchbay",
            source_kind: "report",
            source_event_key: id
          })
        )

      Patchbay.Repo.update_all(
        Ecto.Query.where(Oban.Job, id: ^checking.id),
        [set: [state: "executing"]],
        prefix: Oban.config().prefix
      )

      assert {:error, :post_being_checked} =
               perform_job(Points.Correction, %{kind: "report", id: id})

      assert entries("report", id) == earned
    end

    test "a post published again before the correction runs keeps what it earned",
         %{id: id, earned: earned} do
      moderator = moderator()
      {:ok, hidden} = Forum.moderate(report(id), :quarantine, "Spam link.", moderator)
      {:ok, _shown} = Forum.moderate(hidden, :publish, "Not spam.", moderator)

      award()
      assert entries("report", id) == earned
    end
  end

  # Jev turns the post away: nothing is written and Points is offered nothing
  # for it. Then Jev lets posts through again.
  defp turned_away(post, kind) do
    JevStandIn.finds("spam", 0.99)
    response = post.()
    assert response.status in [200, 422]
    refute_enqueued(worker: RegentPoints.IntakeWorker, args: %{"source_kind" => kind})
    JevStandIn.accept_posts()
  end

  defp assert_offered(kind, id) do
    for rule <- @rules, String.contains?(rule, kind) do
      assert_enqueued(
        worker: RegentPoints.IntakeWorker,
        args: %{
          "rule_id" => rule,
          "source_app" => "patchbay",
          "source_kind" => kind,
          "source_event_key" => id
        }
      )
    end
  end

  # Points does everything waiting for it, as its queue would on its own.
  defp award do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true)
  end

  # The test reads back what Points recorded for one post or bid.
  defp events(kind, id) do
    RegentPoints.Event
    |> Ash.Query.filter(
      source_app == "patchbay" and source_kind == ^kind and source_event_key == ^id
    )
    |> then(&RegentPoints.read_events!(query: &1, actor: @system))
  end

  # A give-back is kept under the event of the award it gives back.
  defp entries(kind, id) do
    ids = Enum.map(events(kind, id), & &1.id)

    RegentPoints.Entry
    |> Ash.Query.filter(event_id in ^ids)
    |> Ash.Query.sort(recorded_at: :asc, id: :asc)
    |> then(&RegentPoints.read_entries!(query: &1, actor: @system))
  end

  # The test reads back the report it wrote.
  defp report(id), do: Forum.get_report!(id, authorize?: false)

  defp only_reply(report_id) do
    # The test reads back the one reply it wrote.
    %{results: [reply]} = Forum.list_replies_for_report!(report_id, authorize?: false)
    reply
  end

  defp question do
    %{
      "site" => "checked.example.net",
      "title" => "Does export work?",
      "body_markdown" => "I called export_orders and it returned an empty file."
    }
  end

  defp tool_report do
    %{
      "origin" => "https://shop.example.com/checkout",
      "tool_name" => "add_to_cart",
      "arguments" => %{"sku" => "A-1"},
      "verdict" => "verified_failure",
      "note" => "The tool said it worked but the cart stayed empty."
    }
  end

  defp send_json(conn, agent, path, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(path, Jason.encode!(Map.put_new(params, "client_request_id", Ecto.UUID.generate())))
  end

  defp earn_on(rules) do
    config = Application.get_all_env(:regent_points)

    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -1, :day))
    Application.put_env(:regent_points, :approved_rules, rules)

    on_exit(fn ->
      Enum.each(config, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)
  end
end
