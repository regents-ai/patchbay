defmodule Patchbay.Points.AwardTest do
  @moduledoc """
  What Patchbay offers Regent Points as people post (`Patchbay.Points.Award`),
  what this site's checks let earn (`Patchbay.Points.PublishedReply`,
  `Patchbay.Points.PublishedReport`), and what moderation takes back. As
  Patchbay ships, nothing earns: no rule is approved and no start is set, so a
  reply offers nothing, moderation takes nothing back, and Points writes
  nothing. With the two rules approved and a start set, as Sean would set them,
  each earns as the catalog prices it, for the person behind the post, each of
  the refusals below holds, and a post moderation hides or sets aside after it
  earned loses its points. Writers post through the board's own doors: a paired
  agent through the API, a person through the form's action; moderators
  moderate through the moderation door.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Reply
  alias Patchbay.ModeratorFixtures
  alias Patchbay.Points.PublishedReply
  alias Patchbay.Points.PublishedReport
  alias Patchbay.Points.TakeBack
  alias PatchbayWeb.SignedAgent
  alias RegentPoints.Rules
  alias RegentPoints.Store

  @rules ["patchbay.report_published", "patchbay.reply_published"]

  setup do
    SignedAgent.stub_siwa()
  end

  describe "as Patchbay ships" do
    test "the checks are installed, nothing earns, a reply offers nothing and moderation takes nothing" do
      assert Rules.adapter("patchbay.report_published") == PublishedReport
      assert Rules.adapter("patchbay.reply_published") == PublishedReply
      assert Rules.tracked() == []

      asker = SignedAgent.pair!()
      helper = SignedAgent.pair!()
      thread_id = ask!(asker)
      answer = reply!(helper, thread_id)
      human_reply!(SignedAgent.pair!().owner, thread_id)

      moderate!(Ash.get!(Reply, answer), :quarantine)
      moderate!(Ash.get!(Forum.Report, thread_id), :redact)

      refute_enqueued(worker: RegentPoints.IntakeWorker)
      refute_enqueued(worker: TakeBack)
      assert points() == {%{}, %{}}
      assert RegentPoints.read_entries!(actor: Store.system()) == []
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
      moderate!(Ash.get!(Reply, hidden), :quarantine)

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
      moderate!(Ash.get!(Forum.Report, thread_id), :quarantine)

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

    test "a reply that earned loses its points once it is hidden, and showing it again earns nothing back" do
      thread_id = ask!(SignedAgent.pair!())
      helper = SignedAgent.pair!()
      answer = reply!(helper, thread_id)

      {earned, _refused} = points()
      assert %{points: 5, taken_back: 0} = earned[{"patchbay.reply_published", answer}]

      moderate!(Ash.get!(Reply, answer), :quarantine)
      {earned, _refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.reply_published", answer}]
      assert balance(helper) == 0

      # Shown again and offered again, Points keeps the one award it made.
      moderate!(Ash.get!(Reply, answer), :publish)
      offer!("patchbay.reply_published", "reply", answer)
      {earned, refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.reply_published", answer}]
      assert refused == %{}
      assert balance(helper) == 0
    end

    test "a reply that earned loses its points once it is set aside as spam, and only once" do
      thread_id = ask!(SignedAgent.pair!())
      helper = SignedAgent.pair!()
      answer = reply!(helper, thread_id)
      {_earned, _refused} = points()

      # A word that leaves it able to earn queues nothing and takes nothing.
      Forum.set_reward_eligibility!(Ash.get!(Reply, answer), :eligible, authorize?: false)
      refute_enqueued(worker: TakeBack)
      {earned, _refused} = points()
      assert %{points: 5, taken_back: 0} = earned[{"patchbay.reply_published", answer}]

      # Two words while the take-back waits are one job.
      Forum.set_reward_eligibility!(Ash.get!(Reply, answer), :ineligible_spam, authorize?: false)
      moderate!(Ash.get!(Reply, answer), :redact)
      assert [_one] = all_enqueued(worker: TakeBack)

      {earned, _refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.reply_published", answer}]
      assert balance(helper) == 0

      # A word after it ran is a new job, which takes nothing more.
      moderate!(Ash.get!(Reply, answer), :quarantine)
      assert [_again] = all_enqueued(worker: TakeBack)
      {earned, _refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.reply_published", answer}]
      assert balance(helper) == 0
    end

    test "moderation is saved when Points cannot take back, and the job takes it back later" do
      thread_id = ask!(SignedAgent.pair!())
      helper = SignedAgent.pair!()
      answer = reply!(helper, thread_id)
      {_earned, _refused} = points()

      # Points' ledger cannot be read, only while this test lasts.
      Patchbay.Repo.query!("ALTER TABLE regent_points.point_events RENAME TO point_events_away")

      assert %{visibility: :quarantined} = moderate!(Ash.get!(Reply, answer), :quarantine)
      assert %{failure: 1, discard: 0} = Oban.drain_queue(queue: :points)

      assert %Oban.Job{state: "retryable", errors: [_attempt]} =
               Patchbay.Repo.get_by!(Oban.Job, worker: inspect(TakeBack))

      assert %{visibility: :quarantined} = Ash.get!(Reply, answer)

      # Points answers again: the waiting job takes the award back, once.
      Patchbay.Repo.query!("ALTER TABLE regent_points.point_events_away RENAME TO point_events")
      assert %{success: 1} = Oban.drain_queue(queue: :points, with_scheduled: true)

      {earned, _refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.reply_published", answer}]
      assert balance(helper) == 0
    end

    test "a thread that earned loses its points once it is hidden, and showing it again earns nothing back" do
      asker = SignedAgent.pair!()
      thread_id = ask!(asker)
      answer = reply!(SignedAgent.pair!(), thread_id)

      {earned, _refused} = points()
      assert %{points: 10, taken_back: 0} = earned[{"patchbay.report_published", thread_id}]

      moderate!(Ash.get!(Forum.Report, thread_id), :quarantine)
      {earned, _refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.report_published", thread_id}]
      assert balance(asker) == 0

      # The reply on it keeps what it earned; only the thread was hidden.
      assert %{points: 5, taken_back: 0} = earned[{"patchbay.reply_published", answer}]

      # Shown again, the next reply offers the thread again and Points keeps
      # the one award it made.
      moderate!(Ash.get!(Forum.Report, thread_id), :publish)
      later = reply!(SignedAgent.pair!(), thread_id)
      {earned, refused} = points()
      assert %{points: 0, taken_back: 1} = earned[{"patchbay.report_published", thread_id}]
      assert %{points: 5} = earned[{"patchbay.reply_published", later}]
      assert refused == %{}
      assert balance(asker) == 0
    end

    test "a post Points cannot find earns nothing" do
      reply_id = Ecto.UUID.generate()
      report_id = Ecto.UUID.generate()
      offer!("patchbay.reply_published", "reply", reply_id)
      offer!("patchbay.report_published", "report", report_id)

      assert points() ==
               {%{},
                %{
                  {"patchbay.reply_published", reply_id} => "reply_not_found",
                  {"patchbay.report_published", report_id} => "report_not_found"
                }}
    end

    # Pairing writes its history row in the pairing's own transaction, so no
    # door posts for a pairing without one; the reply is saved as it would
    # stand if the history were not there yet.
    test "an agent's reply whose pairing history is not there yet is tried again later, not refused" do
      thread_id = ask!(SignedAgent.pair!())
      helper = SignedAgent.pair!()

      reply =
        Ash.Seed.seed!(Reply, %{
          report_id: thread_id,
          browser_session_id: Ecto.UUID.generate(),
          body_markdown: "POST /cart/restore does it.",
          author_kind: :agent,
          privy_user_id: helper.owner.privy_user_id,
          pairing_id: Ecto.UUID.generate()
        })

      offer!("patchbay.reply_published", "reply", reply.id)
      assert %{failure: 1, discard: 0} = Oban.drain_queue(queue: :points)

      assert %Oban.Job{state: "retryable", errors: [%{"error" => error}]} =
               Patchbay.Repo.get_by!(Oban.Job, worker: "RegentPoints.IntakeWorker")

      assert error =~ "pairing_history_missing"
      assert points() == {%{}, %{}}
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
  # what it awarded, with the account, the points it stands at after any
  # correction, how many corrections took points back, and the evidence; and
  # what it refused, with the reason.
  defp points do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true)

    entries = Enum.group_by(RegentPoints.read_entries!(actor: Store.system()), & &1.event_id)

    earned =
      Map.new(RegentPoints.read_events!(actor: Store.system()), fn event ->
        rows = Map.get(entries, event.id, [])

        {{event.rule_id, event.source_event_key},
         %{
           account_id: event.account_id,
           actor_kind: event.actor_kind,
           actor_id: event.actor_id,
           points: div(Enum.sum_by(rows, & &1.points_micro_delta), Rules.unit()),
           taken_back: Enum.count(rows, &(&1.reversal_of_entry_id != nil)),
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

  defp balance(%{account: account}) do
    query = Ash.Query.filter(RegentPoints.Account, id == ^account.id)
    [points] = RegentPoints.read_accounts!(query: query, actor: Store.system())
    div(points.balance_micro, Rules.unit())
  end

  # Offers a source to Points through its own intake, as the site's listener does.
  defp offer!(rule, kind, id) do
    {:ok, _queued} =
      RegentPoints.record_event(
        %{rule_id: rule, source_app: "patchbay", source_kind: kind, source_event_key: id},
        actor: Store.system()
      )
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

  # A moderator's word, through the moderation door.
  defp moderate!(record, action) do
    {:ok, moderated} =
      Forum.moderate(record, action, "Moderation's reason.", ModeratorFixtures.moderator())

    moderated
  end
end
