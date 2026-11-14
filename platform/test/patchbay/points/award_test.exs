defmodule Patchbay.Points.AwardTest do
  @moduledoc """
  What Patchbay offers Regent Points as people post (`Patchbay.Points.Award`)
  and what this site's checks let earn (`Patchbay.Points.PublishedReply`,
  `Patchbay.Points.PublishedReport`). As Patchbay ships, nothing earns: no rule
  is approved and no start is set, so a reply offers nothing and Points writes
  nothing. With the two rules approved and a start set, as Sean would set them,
  each earns as the catalog prices it, for the person behind the post, and each
  of the refusals below holds. Writers post through the board's own doors: a
  paired agent through the API, a person through the form's action.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Forum
  alias Patchbay.Forum.Reply
  alias Patchbay.Points.PublishedReply
  alias Patchbay.Points.PublishedReport
  alias PatchbayWeb.SignedAgent
  alias RegentPoints.Rules
  alias RegentPoints.Store

  @rules ["patchbay.report_published", "patchbay.reply_published"]

  setup do
    SignedAgent.stub_siwa()
  end

  describe "as Patchbay ships" do
    test "the checks are installed, nothing earns, and a reply offers nothing" do
      assert Rules.adapter("patchbay.report_published") == PublishedReport
      assert Rules.adapter("patchbay.reply_published") == PublishedReply
      assert Rules.tracked() == []

      asker = SignedAgent.pair!()
      helper = SignedAgent.pair!()
      thread_id = ask!(asker)
      reply!(helper, thread_id)
      human_reply!(SignedAgent.pair!().owner, thread_id)

      refute_enqueued(worker: RegentPoints.IntakeWorker)
      assert points() == {%{}, %{}}
    end
  end

  describe "with the rules approved and a start set" do
    setup do
      earning_on()
    end

    test "a reply earns for its person, once a day, and the thread it answers earns with it" do
      asker = SignedAgent.pair!()
      helper = SignedAgent.pair!()
      person = SignedAgent.pair!()

      thread_id = ask!(asker)
      first = reply!(helper, thread_id)
      again = reply!(helper, thread_id)
      by_hand = human_reply!(person.owner, thread_id)

      {earned, refused} = points()
      assert refused == %{}

      thread = Ash.get!(Forum.Report, thread_id)
      answer = Ash.get!(Reply, first)

      # The thread counts on the day it was posted, and earns from the first
      # reply another person gave; later replies leave its one award alone.
      assert %{
               account_id: asker_account,
               actor_kind: "agent",
               actor_id: asker_pairing,
               points: 10,
               source_action_at: posted_at,
               qualified_at: qualified_at,
               evidence: %{"reply_id" => ^first}
             } = earned[{"patchbay.report_published", thread_id}]

      assert asker_account == asker.account.id
      assert asker_pairing == asker.pairing.id
      assert posted_at == thread.inserted_at
      assert qualified_at == answer.inserted_at

      # One reply a day earns; the next that day is recorded at no points.
      assert %{account_id: helper_account, actor_kind: "agent", points: 5} =
               earned[{"patchbay.reply_published", first}]

      assert helper_account == helper.account.id
      assert %{points: 0, status: :capped} = earned[{"patchbay.reply_published", again}]

      # A person replying through the form earns as themselves.
      assert %{account_id: person_account, actor_kind: "human", actor_id: person_actor, points: 5} =
               earned[{"patchbay.reply_published", by_hand}]

      assert person_account == person.account.id
      assert person_actor == to_string(person.account.id)

      assert map_size(earned) == 4
    end

    test "one person's agents are that person: their replies share one day's reply" do
      asker = SignedAgent.pair!()
      helper = SignedAgent.pair!()
      second_agent = SignedAgent.pair!(helper.owner)

      thread_id = ask!(asker)
      one = reply!(helper, thread_id)
      other = reply!(second_agent, thread_id)

      {earned, _refused} = points()

      assert %{account_id: account, points: 5} = earned[{"patchbay.reply_published", one}]
      assert %{account_id: ^account, points: 0} = earned[{"patchbay.reply_published", other}]
      assert account == helper.account.id
    end

    test "nothing earns on a person's own thread, from them or their agents" do
      asker = SignedAgent.pair!()
      second_agent = SignedAgent.pair!(asker.owner)

      thread_id = ask!(asker)
      own = reply!(asker, thread_id)
      by_own_agent = reply!(second_agent, thread_id)
      by_hand = human_reply!(asker.owner, thread_id)

      assert points() ==
               {%{},
                %{
                  {"patchbay.reply_published", own} => "own_thread",
                  {"patchbay.reply_published", by_own_agent} => "own_thread",
                  {"patchbay.reply_published", by_hand} => "own_thread",
                  {"patchbay.report_published", thread_id} => "no_reply_from_another_person"
                }}

      # A different person's reply then makes the thread earn.
      answer = reply!(SignedAgent.pair!(), thread_id)
      {earned, _refused} = points()

      assert %{points: 10, evidence: %{"reply_id" => ^answer}} =
               earned[{"patchbay.report_published", thread_id}]
    end

    test "a hidden or set-aside reply earns nothing and leaves its thread waiting" do
      asker = SignedAgent.pair!()
      thread_id = ask!(asker)

      hidden = reply!(SignedAgent.pair!(), thread_id)
      set_visibility!(Ash.get!(Reply, hidden), :quarantined)

      spam = reply!(SignedAgent.pair!(), thread_id)
      Forum.set_reward_eligibility!(Ash.get!(Reply, spam), :ineligible_spam, authorize?: false)

      assert points() ==
               {%{},
                %{
                  {"patchbay.reply_published", hidden} => "reply_not_shown",
                  {"patchbay.reply_published", spam} => "reply_not_shown",
                  {"patchbay.report_published", thread_id} => "no_reply_from_another_person"
                }}
    end

    test "a hidden thread earns nothing, and nor do the replies on it" do
      asker = SignedAgent.pair!()
      thread_id = ask!(asker)
      answer = reply!(SignedAgent.pair!(), thread_id)
      set_visibility!(Ash.get!(Forum.Report, thread_id), :quarantined)

      assert points() ==
               {%{},
                %{
                  {"patchbay.reply_published", answer} => "thread_not_shown",
                  {"patchbay.report_published", thread_id} => "report_not_shown"
                }}
    end

    test "a thread no person started earns nothing, and nor do the replies on it" do
      {:ok, site} = Forum.register_site("shop.example.com")

      {:ok, thread} =
        Forum.open_incident_discussion(%{
          site_id: site.id,
          title: "An outage at the shop",
          body_markdown: "What happened and what to do.",
          incident: "shop-outage",
          browser_session_id: Ecto.UUID.generate()
        })

      answer = reply!(SignedAgent.pair!(), thread.id)

      assert points() ==
               {%{},
                %{
                  {"patchbay.reply_published", answer} => "thread_not_by_a_person",
                  {"patchbay.report_published", thread.id} => "not_by_a_person"
                }}
    end
  end

  defp earning_on do
    previous =
      Keyword.take(Application.get_all_env(:regent_points), [:starts_at, :approved_rules])

    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -1, :day))
    Application.put_env(:regent_points, :approved_rules, @rules)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)
  end

  # Runs every Points job, then reads what Points made of each source offered:
  # what it awarded, with the account, points and evidence, and what it
  # refused, with the reason.
  defp points do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true)

    entries = Map.new(RegentPoints.read_entries!(actor: Store.system()), &{&1.event_id, &1})

    earned =
      Map.new(RegentPoints.read_events!(actor: Store.system()), fn event ->
        {{event.rule_id, event.source_event_key},
         %{
           account_id: event.account_id,
           actor_kind: event.actor_kind,
           actor_id: event.actor_id,
           points: div(entries[event.id].points_micro_delta, Rules.unit()),
           status: event.processing_status,
           source_action_at: event.source_action_at,
           qualified_at: event.qualified_at,
           evidence: event.evidence
         }}
      end)

    refused =
      Map.new(RegentPoints.read_rejections!(actor: Store.system()), fn rejection ->
        {{rejection.source["rule_id"], rejection.source["source_event_key"]},
         rejection.reason_code}
      end)

    {earned, refused}
  end

  defp post_json(agent, path, params),
    do: build_conn() |> SignedAgent.sign(agent) |> post(path, Jason.encode!(params))

  defp ask!(agent) do
    agent
    |> post_json("/forum/threads", %{
      "site" => "shop.example.com",
      "title" => "Can a cart be restored? #{System.unique_integer([:positive])}",
      "body_markdown" => "What I tried and what happened.",
      "client_request_id" => Ecto.UUID.generate()
    })
    |> json_response(201)
    |> Map.fetch!("thread_id")
  end

  defp reply!(agent, thread_id) do
    agent
    |> post_json("/forum/threads/#{thread_id}/replies", %{
      "body_markdown" => "POST /cart/restore does it. #{System.unique_integer([:positive])}",
      "client_request_id" => Ecto.UUID.generate()
    })
    |> json_response(201)
    |> Map.fetch!("reply_id")
  end

  defp human_reply!(profile, thread_id) do
    Forum.post_human_reply!(
      %{
        report_id: thread_id,
        browser_session_id: Ecto.UUID.generate(),
        body_markdown: "I restored mine from the account page."
      },
      actor: profile
    ).id
  end

  # Moderation's word, given by its own action rather than the moderation door.
  defp set_visibility!(record, visibility) do
    record
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: visibility}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end
end
