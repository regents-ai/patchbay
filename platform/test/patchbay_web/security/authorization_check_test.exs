defmodule PatchbayWeb.Security.AuthorizationCheckTest do
  @moduledoc """
  Access-rule checks for Patchbay, part of the regular suite.

  Three people take part: `a`, who owns the posts, agents and records under
  test; `b`, another signed-in person who tries to reach them; and a moderator
  on the moderator list, set the way the Offers tests set it
  (`Patchbay.OffersFixtures.moderator/0`). Every check says what it expected
  and what it saw. The moderator list is application-wide, so this file runs
  alone (`async: false`).
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Identity
  alias Patchbay.JevStandIn
  alias Patchbay.OffersFixtures
  alias Patchbay.Repo
  alias PatchbayWeb.Forum.Troubleshooting
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  @site "authz-shop.example"

  setup do
    SignedAgent.stub_siwa()

    a = person!("a", "a1")
    b = person!("b", "b2")
    a_agent = SignedAgent.pair!(a)
    b_agent = SignedAgent.pair!(b)

    %{a: a, b: b, a_agent: a_agent, b_agent: b_agent, moderator: OffersFixtures.moderator()}
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp person!(name, hex) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:authz-#{name}-#{System.unique_integer([:positive])}",
      wallet_address: "0x" <> String.duplicate(hex, 20)
    })
  end

  defp as(nil), do: build_conn()

  defp as(profile),
    do: build_conn() |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(profile.id)

  defp signed(agent), do: build_conn() |> SignedAgent.sign(agent)

  defp post_json(agent, path, body),
    do: agent |> signed() |> post(path, Jason.encode!(body))

  # The status a request ends in, the way a browser sees it: an exception a
  # plug turns into a status (a missing route, a body too large) counts as
  # that status, and any other exception as a 500.
  defp outcome(fun) do
    conn = fun.()
    {conn.status, conn}
  rescue
    error -> {Plug.Exception.status(error), error}
  end

  defp expect(label, expected, actual) do
    assert expected == actual,
           "#{label}\n  expected: #{inspect(expected)}\n  actual:   #{inspect(actual)}"
  end

  defp expect_absent(label, html, secret) do
    refute html =~ secret,
           "#{label}\n  expected: #{inspect(secret)} nowhere on the page\n  actual:   it appears"
  end

  defp expect_present(label, html, text) do
    assert html =~ text,
           "#{label}\n  expected: #{inspect(text)} on the page\n  actual:   it is missing"
  end

  defp site!, do: Forum.register_site!(@site)

  # A thread by `profile` through the domain, as the form posts it. Used where
  # the write itself is not what the check is about.
  defp thread!(profile, attrs \\ %{}) do
    Forum.ask_question!(
      Map.merge(
        %{
          site_id: site!().id,
          browser_session_id: Ash.UUID.generate(),
          title: "authz thread #{System.unique_integer([:positive])}",
          thread_kind: :help_needed,
          body_markdown: "What I tried and what happened."
        },
        attrs
      ),
      actor: profile,
      private_arguments: %{author_kind: :human}
    )
  end

  defp reply!(thread, profile, body \\ "Try the restore endpoint.") do
    Forum.post_human_reply!(
      %{report_id: thread.id, browser_session_id: Ash.UUID.generate(), body_markdown: body},
      actor: profile
    )
  end

  defp ask(agent, title, extra \\ %{}) do
    post_json(
      agent,
      "/forum/threads",
      Map.merge(
        %{
          "site" => @site,
          "title" => title,
          "body_markdown" => "What I tried and what happened.",
          "client_request_id" => Ecto.UUID.generate()
        },
        extra
      )
    )
  end

  defp person(profile), do: %RegentAgents.Person{privy_user_id: profile.privy_user_id}

  defp paired_ids(profile) do
    {:ok, agents} = RegentAgents.list_my_agents(actor: person(profile))
    agents |> Enum.map(& &1.id) |> Enum.sort()
  end

  # The post form previews first and publishes only what was previewed.
  defp form_post(conn, typed, extra \\ %{}) do
    preview =
      conn |> post(~p"/threads", %{"ask" => typed, "step" => "preview"}) |> html_response(200)

    [_, digest] = Regex.run(~r/name="previewed" value="([^"]+)"/, preview)

    conn
    |> post(
      ~p"/threads",
      Map.merge(%{"ask" => typed, "step" => "post", "previewed" => digest}, extra)
    )
  end

  defp seed_points!(profile, points) do
    {:ok, %{id: account_id}} =
      Patchbay.Accounts.by_privy(profile.privy_user_id, actor: %{role: :system})

    now = DateTime.utc_now()
    Ash.Seed.seed!(RegentPoints.Account, %{id: account_id})

    # A test's own ledger line, written straight into the shared tables.
    event =
      Ash.Seed.seed!(RegentPoints.Event, %{
        program_id: "regents",
        source_app: "patchbay",
        source_kind: "authz_check",
        source_event_key: Ecto.UUID.generate(),
        rule_id: "patchbay.report_published",
        account_id: account_id,
        actor_kind: "human",
        actor_id: profile.privy_user_id,
        source_action_at: now,
        qualified_at: now,
        evidence_ref: "authz",
        payload_digest: String.duplicate("0", 64),
        evidence: %{},
        rule_snapshot: %{},
        award_key: Ecto.UUID.generate(),
        processing_status: :confirmed
      })

    Ash.Seed.seed!(RegentPoints.Entry, %{
      program_id: "regents",
      account_id: account_id,
      event_id: event.id,
      award_key: event.award_key,
      rule_id: "patchbay.report_published",
      rule_version: 1,
      source_app: "patchbay",
      actor_kind: "human",
      actor_id: profile.privy_user_id,
      category: "authz",
      points_micro_delta: points * 1_000_000,
      earned_at: now,
      reason_code: "authz"
    })

    RegentPoints.Amount.format(points * 1_000_000)
  end

  # ---------------------------------------------------------------------------
  # 1. Ownership

  describe "1. ownership" do
    test "no route edits or deletes a post or a reply, and the resource refuses b", %{
      a: a,
      b: b
    } do
      thread = thread!(a)
      reply = reply!(thread, a)

      for {method, path} <- [
            {:put, "/posts/#{thread.id}"},
            {:patch, "/posts/#{thread.id}"},
            {:delete, "/posts/#{thread.id}"},
            {:put, "/forum/threads/#{thread.id}"},
            {:delete, "/forum/threads/#{thread.id}"},
            {:patch, "/forum/replies/#{reply.id}"},
            {:delete, "/forum/replies/#{reply.id}"}
          ] do
        {status, _} =
          outcome(fn ->
            dispatch(as(b), @endpoint, method, path, %{"title" => "b was here"})
          end)

        expect("#{method} #{path} as b", 404, status)
      end

      expect("Report.set_visibility as b", :forbidden, redact_as(thread, b))
      expect("Reply.set_visibility as b", :forbidden, redact_as(reply, b))

      expect("thread title after b's attempts", thread.title, Ash.get!(Report, thread.id).title)
      expect("reply visibility", :published, Ash.get!(Reply, reply.id).visibility)
    end

    test "b cannot mark the solution on a's thread, on the page or through the API", %{
      a: a,
      b: b,
      a_agent: a_agent,
      b_agent: b_agent
    } do
      thread = thread!(a)
      reply = reply!(thread, b)

      as(b) |> post("/posts/#{thread.id}/solution", %{"reply_id" => reply.id})
      expect("solution after b's form press", nil, Ash.get!(Report, thread.id).solution_reply_id)

      %{"thread_id" => api_thread} = a_agent |> ask("authz api thread") |> json_response(201)

      %{"reply_id" => api_reply} =
        b_agent
        |> post_json("/forum/threads/#{api_thread}/replies", %{
          "body_markdown" => "Use restore.",
          "client_request_id" => Ecto.UUID.generate()
        })
        |> json_response(201)

      refused =
        post_json(b_agent, "/forum/threads/#{api_thread}/solution", %{"reply_id" => api_reply})

      expect("b's agent marking a's thread", {403, "not_asker"}, {
        refused.status,
        json_response(refused, 403)["error"]["code"]
      })

      # The same presses by the asker do mark it, so the refusals above are b's.
      as(a) |> post("/posts/#{thread.id}/solution", %{"reply_id" => reply.id})

      expect(
        "solution after a's form press",
        reply.id,
        Ash.get!(Report, thread.id).solution_reply_id
      )

      expect(
        "a's agent marking its thread",
        201,
        post_json(a_agent, "/forum/threads/#{api_thread}/solution", %{"reply_id" => api_reply}).status
      )
    end

    test "after a signs out, b signing in on the same browser is not a's asker", %{a: a, b: b} do
      shared = Ash.UUID.generate()
      thread = thread!(a, %{browser_session_id: shared})
      reply = reply!(thread, b)

      a_conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"forum_session_id" => shared})
        |> CurrentProfile.sign_in(a.id)
        |> CurrentProfile.sign_out()

      b_conn = CurrentProfile.sign_in(a_conn, b.id)

      kept? = get_session(b_conn, "forum_session_id") == shared
      b_conn |> post("/posts/#{thread.id}/solution", %{"reply_id" => reply.id})
      marked = Ash.get!(Report, thread.id).solution_reply_id

      judge("shared browser", [
        {"the browser's forum identity after a signs out and b signs in", not kept?,
         "a fresh one", if(kept?, do: "a's", else: "a fresh one")},
        {"solution after b's press on a's browser", is_nil(marked), "nil", marked}
      ])
    end

    test "b cannot follow or unfollow for a", %{a: a, b: b, a_agent: a_agent, b_agent: b_agent} do
      site = site!()

      as(a) |> post(~p"/follow", %{"site_id" => site.id, "follow" => "true"})
      a_principal = Forum.Principal.for_profile(a.id)

      # b names a's principal and profile in every way a form could.
      as(b)
      |> post(~p"/follow", %{
        "site_id" => site.id,
        "follow" => "false",
        "principal" => a_principal,
        "profile_id" => a.id
      })

      as(b)
      |> post(~p"/follow", %{
        "site_id" => site.id,
        "follow" => "true",
        "principal" => a_principal,
        "profile_id" => a.id
      })

      expect("a's follows after b's presses", [site.id], site_follows(a_principal))
      expect("b's follows", [site.id], site_follows(Forum.Principal.for_profile(b.id)))

      %{"subscription_id" => sub_id} =
        a_agent |> post_json("/forum/subscriptions", %{"site" => @site}) |> json_response(201)

      gone = b_agent |> signed() |> delete("/forum/subscriptions/#{sub_id}")
      expect("b's agent unsubscribing a's subscription", 404, gone.status)

      listed =
        a_agent |> signed() |> get("/forum/subscriptions") |> json_response(200)

      expect(
        "a's subscriptions after b's attempt",
        true,
        Enum.any?(listed["subscriptions"], &(&1["id"] == sub_id))
      )

      theirs =
        b_agent |> signed() |> get("/forum/subscriptions") |> json_response(200)

      expect(
        "b's agent's subscription list names a's subscription",
        false,
        Enum.any?(theirs["subscriptions"], &(&1["id"] == sub_id))
      )
    end

    test "b cannot unpair a's agent through the Account page or the API", %{
      a: a,
      b: b,
      a_agent: a_agent,
      b_agent: b_agent
    } do
      before = paired_ids(a)
      expect("a's agent is paired", true, a_agent.pairing.id in before)

      {:ok, view, _html} = live(as(b), ~p"/account")

      view
      |> with_target("#account-agents")
      |> render_click("unpair_agent", %{"id" => a_agent.pairing.id})

      expect("a's agents after b's unpair event", before, paired_ids(a))

      for {method, path} <- [
            {:delete, "/api/agents/v1/agents/#{a_agent.pairing.id}"},
            {:post, "/api/agents/v1/unpair"},
            {:delete, "/api/agents/v1/me"}
          ] do
        conn =
          b_agent
          |> signed()
          |> dispatch(@endpoint, method, path, Jason.encode!(%{"id" => a_agent.pairing.id}))

        expect("#{method} #{path} by b's agent", 404, conn.status)
      end

      expect("a's agents after b's API calls", before, paired_ids(a))

      # The event itself works for the agent's own person.
      view
      |> with_target("#account-agents")
      |> render_click("unpair_agent", %{"id" => b_agent.pairing.id})

      expect("b's own agent after b's unpair", false, b_agent.pairing.id in paired_ids(b))
    end

    test "b cannot read a's Credits history, Points, Past Jev questions or pairing code", %{
      a: a,
      b: b,
      a_agent: a_agent
    } do
      OffersFixtures.give_credits(a, "25")
      a_points = seed_points!(a, 4_321)

      run =
        Patchbay.AssistFixtures.browser_run(%{
          payer_profile_id: a.id,
          goal: "authz private Jev goal of a"
        })

      code = RegentAgents.issue_pairing_code!(actor: person(a)).code

      b_paired = SignedAgent.pair!(b)

      history = fn agent ->
        agent
        |> post_json("/tools/account/credits/history", %{})
        |> json_response(200)
        |> Map.fetch!("entries")
        |> length()
      end

      expect("a's agent: Credits history entries", 1, history.(a_agent))
      expect("b's agent: Credits history entries", 0, history.(b_paired))

      points = fn agent ->
        agent
        |> signed()
        |> get("/tools/account/points")
        |> json_response(200)
        |> Map.take(["points", "entries"])
      end

      expect("a's agent: Points", a_points, points.(a_agent)["points"])

      expect(
        "b's agent: Points",
        {"0", []},
        {points.(b_paired)["points"], points.(b_paired)["entries"]}
      )

      {:ok, a_view, _} = live(as(a), ~p"/points")
      expect_present("a's Points page", render_async(a_view), a_points)
      {:ok, b_view, _} = live(as(b), ~p"/points")
      expect_absent("b's Points page shows a's Points", render_async(b_view), a_points)

      {:ok, _, a_profile} = live(as(a), ~p"/account/profile")
      expect_present("a's Profile tab", a_profile, run.goal)
      {:ok, _, b_profile} = live(as(b), ~p"/account/profile")
      expect_absent("b's Profile tab shows a's Past Jev question", b_profile, run.goal)

      expect(
        "b opening a's Jev question",
        {:error, {:redirect, %{to: "/"}}},
        live(as(b), ~p"/fixes/#{run.id}") |> without_flash()
      )

      expect("a opening a's Jev question", :ok, elem(live(as(a), ~p"/fixes/#{run.id}"), 0))

      for path <- [~p"/account", ~p"/account/profile", ~p"/points", ~p"/"] do
        {_status, conn} = outcome(fn -> get(as(b), path) end)
        expect_absent("b's #{path} shows a's pairing code", conn.resp_body, code)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Fields a caller may not set

  # Every field the brief names, under the names a caller would guess, with
  # values that would show if any of them were taken.
  defp extras(b) do
    %{
      "role" => "moderator",
      "moderator" => "true",
      "owner_id" => b.id,
      "owner_profile_id" => b.id,
      "author_profile_id" => b.id,
      "profile_id" => b.id,
      "beneficiary_profile_id" => b.id,
      "inserted_at" => "2001-01-01T00:00:00Z",
      "status" => "refused",
      "visibility" => "quarantined",
      "points" => "9999",
      "tool_count" => "99",
      "refreshed_at" => "2001-01-01T00:00:00Z",
      "screenshot_captured_at" => "2001-01-01T00:00:00Z",
      "verified" => "true",
      "author_kind" => "operator"
    }
  end

  # What a caller must never have set on a thread, its reply or its site.
  defp untouched(record, b) do
    record = Ash.load!(record, [:site], authorize?: false)
    year = record.inserted_at.year

    %{
      author_is_b: record.author_profile_id == b.id,
      backdated: year == 2001,
      visibility: record.visibility,
      site_refreshed: not is_nil(record.site.refreshed_at),
      site_pictured: not is_nil(record.site.screenshot_captured_at)
    }
  end

  @clean %{
    author_is_b: false,
    backdated: false,
    visibility: :published,
    site_refreshed: false,
    site_pictured: false
  }

  describe "2. extra fields are ignored" do
    test "on the post form", %{a: a, b: b} do
      typed = %{
        "goal" => "authz form thread with extras",
        "site_url" => "authz-form.example",
        "details" => "What I tried and what happened."
      }

      posted = form_post(as(a), Map.merge(typed, extras(b)), extras(b))
      [_, id] = Regex.run(~r{^/posts/([^/?]+)}, redirected_to(posted))
      thread = Ash.get!(Report, id)

      expect("form thread: what the caller could not set", @clean, untouched(thread, b))
      expect("form thread author", a.id, thread.author_profile_id)
      expect("form thread author kind", :human, thread.author_kind)
    end

    test "through the API, for a thread and a reply", %{a_agent: a_agent, b: b} do
      %{"thread_id" => id} =
        a_agent |> ask("authz api thread with extras", extras(b)) |> json_response(201)

      %{"thread_id" => plain_id} =
        a_agent |> ask("authz api thread without extras") |> json_response(201)

      thread = Ash.get!(Report, id)
      plain = Ash.get!(Report, plain_id)

      expect("API thread: what the caller could not set", @clean, untouched(thread, b))

      expect(
        "API thread author and kind, with and without extras",
        {plain.author_profile_id, plain.author_kind, plain.verified},
        {thread.author_profile_id, thread.author_kind, thread.verified}
      )

      %{"reply_id" => reply_id} =
        a_agent
        |> post_json(
          "/forum/threads/#{id}/replies",
          Map.merge(extras(b), %{
            "body_markdown" => "An answer with extras.",
            "client_request_id" => Ecto.UUID.generate()
          })
        )
        |> json_response(201)

      reply = Ash.get!(Reply, reply_id)

      expect(
        "API reply author, kind, visibility and date",
        {plain.author_profile_id, :agent, :published, false},
        {reply.author_profile_id, reply.author_kind, reply.visibility,
         reply.inserted_at.year == 2001}
      )
    end

    test "a thread cannot be made into another kind than a poster may pick", %{
      a: a,
      a_agent: a_agent
    } do
      refused = a_agent |> ask("authz kind check", %{"thread_kind" => "failure_report"})
      expect("API thread posted as a failure report", 422, refused.status)

      typed = %{
        "goal" => "authz form kind check",
        "site_url" => "authz-form.example",
        "details" => "What I tried.",
        "thread_kind" => "failure_report"
      }

      page = form_post(as(a), typed)

      expect(
        "form thread posted as a failure report",
        {200, true},
        {page.status, page.resp_body =~ "That post could not be published"}
      )

      expect(
        "threads titled with either kind check",
        [],
        Report
        |> Ash.Query.filter(title in ["authz kind check", "authz form kind check"])
        |> Ash.read!(authorize?: false)
      )
    end

    test "renaming reaches only the signed-in person's own agent name", %{
      a: a,
      b: b,
      b_agent: b_agent
    } do
      {:ok, view, _} = live(as(b), ~p"/account/profile")

      render_submit(
        view,
        "rename",
        Map.merge(extras(b), %{
          "name" => "bnewname",
          "id" => a.id,
          "public_id" => a.public_id,
          "profile_id" => a.id
        })
      )

      expect("a's agent name after b's rename", a.agent_name, agent_name(a))
      expect("b's agent name after b's rename", "bnewname", agent_name(b))

      # b's paired agent names b's agent; nothing it sends reaches a.
      renamed =
        b_agent
        |> post_json("/forum/agent-name", %{
          "agent_name" => "bagentname",
          "display_name" => "hijacked",
          "id" => a.id,
          "public_id" => a.public_id,
          "status" => "suspended",
          "profile_type" => "human"
        })

      expect("b's agent rename", 200, renamed.status)
      expect("a's agent name after b's agent rename", a.agent_name, agent_name(a))
      expect("b's agent name after b's agent rename", "bagentname", agent_name(b))
      expect("b's status after the rename", b.status, Identity.get_profile!(b.id).status)
    end
  end

  defp agent_name(profile), do: Identity.get_profile!(profile.id).agent_name

  # ---------------------------------------------------------------------------
  # 3. Pairing codes

  defp new_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp redeem(wallet, code) do
    %{wallet: wallet}
    |> signed()
    |> post(
      "/api/agents/v1/pair",
      Jason.encode!(%{"code" => code, "name" => "Agent", "harness" => "codex"})
    )
  end

  describe "3. pairing codes work once" do
    test "a second redeem, an expired code and another agent's try are refused", %{a: a} do
      code = RegentAgents.issue_pairing_code!(actor: person(a)).code
      first = new_wallet()

      expect("first redeem", 201, redeem(first, code).status)

      again = redeem(first, code)
      expect("second redeem by the same agent", {400, "pairing_failed"}, refusal(again))

      other = redeem(new_wallet(), code)
      expect("redeem of a spent code by another agent", {400, "pairing_failed"}, refusal(other))

      expired = RegentAgents.issue_pairing_code!(actor: person(a)).code

      Repo.query!(
        "UPDATE regent_agents.pairing_codes SET expires_at = now() - interval '1 minute' WHERE code_hash = $1",
        [RegentAgents.PairingCode.hash(expired)]
      )

      late = redeem(new_wallet(), expired)
      expect("redeem of an expired code", {400, "pairing_failed"}, refusal(late))

      expect("agents a has", 2, length(paired_ids(a)))
    end

    test "agents racing for one code: exactly one pairs", %{a: a} do
      code = RegentAgents.issue_pairing_code!(actor: person(a)).code

      statuses =
        1..10
        |> Task.async_stream(fn _ -> redeem(new_wallet(), code).status end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, status} -> status end)
        |> Enum.frequencies()

      expect("statuses of ten agents racing for one code", %{201 => 1, 400 => 9}, statuses)
    end
  end

  defp refusal(conn), do: {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]}

  # ---------------------------------------------------------------------------
  # 4. Limits under parallel requests
  #
  # The tests share one sandboxed database connection, so the database itself
  # runs their transactions one after another; what runs in parallel is every
  # read and decision a request makes before and between its writes.

  describe "4. limits under parallel requests" do
    test "twenty presses of Refresh this site start one picture and one check", %{conn: conn} do
      site = Forum.register_site!("authz-refresh.example")

      views =
        for i <- 1..20 do
          {:ok, view, _html} =
            live_isolated(conn, PatchbayWeb.SiteRefreshLive,
              session: %{
                "origin" => site.origin,
                "visitor" => "authz-visitor-#{i}",
                "site_edition" => :main
              }
            )

          view
        end

      views
      |> Task.async_stream(&render_click(&1, "refresh", %{}),
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Stream.run()

      pictures =
        all_enqueued(worker: Patchbay.Forum.Site.Workers.RefreshPicture)
        |> Enum.count(&(&1.args["primary_key"]["id"] == site.id))

      checks = length(all_enqueued(worker: Patchbay.Forum.SiteCheck.Workers.Run))

      expect("picture jobs and check jobs started by twenty presses", {1, 1}, {pictures, checks})

      later = render_click(hd(views), "refresh", %{})
      expect_present("the button once a refresh is on its way", later, "disabled")
    end

    test "posts sent at the hourly limit: the ones over it are refused", %{a: a, a_agent: a_agent} do
      Application.put_env(:patchbay, :forum_reports_per_hour, 3)
      on_exit(fn -> Application.delete_env(:patchbay, :forum_reports_per_hour) end)

      second_agent = SignedAgent.pair!(a)

      statuses =
        1..10
        |> Task.async_stream(
          fn i ->
            agent = if rem(i, 2) == 0, do: a_agent, else: second_agent
            ask(agent, "authz budget post #{i}").status
          end,
          max_concurrency: 10,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, status} -> status end)
        |> Enum.frequencies()

      expect("statuses of ten posts against a share of three", %{201 => 3, 429 => 7}, statuses)

      kept =
        Report
        |> Ash.Query.filter(contains(title, "authz budget post"))
        |> Ash.read!(authorize?: false)
        |> length()

      expect("threads kept", 3, kept)
    end

    test "Credits holds in parallel never spend more than the balance" do
      market = Patchbay.Offers.global_market!()
      advertiser = OffersFixtures.advertiser()
      OffersFixtures.give_credits(advertiser, "10")
      version = OffersFixtures.approved_version(advertiser, "Authz fixes flaky builds.", market)

      results =
        for(slot <- 1..3, _ <- 1..2, do: slot)
        |> Task.async_stream(
          &OffersFixtures.bid(advertiser, market, &1, version, "4.00"),
          max_concurrency: 6,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> elem(result, 0) end)

      placed = Enum.count(results, &(&1 == :ok))
      %{available: available, held: held} = OffersFixtures.credits(advertiser)

      expect(
        "bids placed, Credits held and left from 10 with six 4.00 bids",
        {2, "8", "2"},
        {placed, held, available}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Checks that collect every row before judging, so one run shows them all.

  defp judge(section, rows) do
    failed = Enum.reject(rows, fn {_label, ok?, _expected, _actual} -> ok? end)

    report =
      Enum.map_join(failed, "\n", fn {label, _ok?, expected, actual} ->
        "  #{label}\n    expected: #{expected}\n    actual:   #{inspect(actual)}"
      end)

    assert failed == [], "#{section}: #{length(failed)} of #{length(rows)} failed\n" <> report
  end

  defp status_row(label, allowed, fun) do
    {status, _} = outcome(fun)
    {label, status in allowed, "status in #{inspect(allowed)}", status}
  end

  # ---------------------------------------------------------------------------
  # 5. Public pages show nothing private

  describe "5. public pages show nothing private" do
    test "agent pages, troubleshooting pages, a site page and a post page", %{
      a: a,
      b: b,
      a_agent: a_agent,
      moderator: moderator
    } do
      code = RegentAgents.issue_pairing_code!(actor: person(a)).code
      published = thread!(a, %{title: "authz published question"})
      reply!(published, b, "authz public answer")

      hidden = thread!(a, %{title: "authz quarantined question"})
      {:ok, _} = Forum.moderate(hidden, :quarantine, "authz moderator note one", moderator)

      hidden_reply = reply!(published, a, "authz quarantined reply")
      {:ok, _} = Forum.moderate(hidden_reply, :redact, "authz moderator note two", moderator)

      JevStandIn.finds("spam", 0.95)
      expect("refused post", 422, (a_agent |> ask("authz refused question")).status)
      JevStandIn.accept_posts()

      run =
        Patchbay.AssistFixtures.browser_run(%{payer_profile_id: a.id, goal: "authz private goal"})

      secrets = [
        {"pairing code", code},
        {"Privy user id (Patchbay keeps no email)", a.privy_user_id},
        {"profile id", a.id},
        {"quarantined post", "authz quarantined question"},
        {"redacted reply", "authz quarantined reply"},
        {"refused post", "authz refused question"},
        {"moderator note", "authz moderator note"},
        {"Past Jev question", run.goal}
      ]

      pages =
        Enum.map(~w(dots claude grokbot hermes muse), &"/#{&1}") ++
          Enum.map(Troubleshooting.harnesses(), &Troubleshooting.path/1) ++
          ["/" <> @site, PostAddress.path(published)]

      expect("troubleshooting pages", 10, length(Troubleshooting.harnesses()))

      rows =
        for path <- pages, {who, viewer} <- [{"a", a}, {"b", b}, {"logged out", nil}] do
          {status, conn} = outcome(fn -> get(as(viewer), path) end)
          body = if is_struct(conn, Plug.Conn), do: conn.resp_body, else: ""

          shown =
            if who == "a",
              do: [],
              else: for({name, secret} <- secrets, body =~ secret, do: name)

          {"#{path} as #{who}", status == 200 and shown == [],
           "200 and none of a's private details", {status, shown}}
        end

      judge("public pages", rows)

      post_page = get(as(nil), PostAddress.path(published)).resp_body
      expect_present("the post page as a visitor", post_page, "authz public answer")

      expect_present(
        "the site page as a visitor",
        get(as(nil), "/" <> @site).resp_body,
        published.title
      )
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Input handling

  defp raw(conn, path, content_type, body),
    do: conn |> put_req_header("content-type", content_type) |> post(path, body)

  defp multipart(size) do
    boundary = "authzboundary"

    body =
      ~s(--#{boundary}\r\ncontent-disposition: form-data; name="ask[pictures][]"; filename="big.png"\r\n) <>
        "content-type: image/png\r\n\r\n" <>
        :binary.copy("x", size) <> "\r\n--#{boundary}--\r\n"

    {"multipart/form-data; boundary=#{boundary}", body}
  end

  describe "6. input handling" do
    test "oversized, odd, null and wrongly typed input is refused cleanly", %{
      a: a,
      a_agent: a_agent
    } do
      thread = thread!(a)
      big = :binary.copy("x", 9_000_000)
      {multipart_type, multipart_body} = multipart(11_000_000)
      bad = ["4xx: 400, 413 or 422", [400, 413, 422]]
      [_, refused] = bad
      fine = [200, 201, 302 | refused]

      form = fn params -> fn -> as(a) |> post(~p"/threads", params) end end

      api = fn path, body -> fn -> a_agent |> signed() |> post(path, body) end end

      odd = "authz \u202Eevil\u200B\u0301 \u{1F9EA} \uFEFF \uFDFD title"

      rows = [
        status_row("form: 9 MB urlencoded body", [413], fn ->
          as(a) |> raw(~p"/threads", "application/x-www-form-urlencoded", "ask[details]=" <> big)
        end),
        status_row("form: 11 MB multipart body", [413], fn ->
          as(a) |> raw(~p"/threads", multipart_type, multipart_body)
        end),
        status_row("form: invalid UTF-8", refused, fn ->
          as(a)
          |> raw(~p"/threads", "application/x-www-form-urlencoded", "ask[goal]=%FF%FE&step=post")
        end),
        status_row(
          "form: odd unicode, preview",
          fine,
          form.(%{
            "ask" => %{"goal" => odd, "site_url" => "authz-odd.example"},
            "step" => "preview"
          })
        ),
        status_row("form: odd unicode, publish", fine, fn ->
          form_post(as(a), %{"goal" => odd, "site_url" => "authz-odd.example", "details" => odd})
        end),
        status_row("form: null bytes, publish", fine, fn ->
          form_post(as(a), %{
            "goal" => "authz null \u0000 title",
            "site_url" => "authz-odd.example",
            "details" => "null \u0000 body",
            "topic_tags" => "a\u0000b"
          })
        end),
        status_row("form: ask is text", fine, form.(%{"ask" => "text", "step" => "post"})),
        status_row(
          "form: goal is a map",
          fine,
          form.(%{"ask" => %{"goal" => %{"x" => "y"}}, "step" => "preview"})
        ),
        status_row(
          "form: tools is text",
          fine,
          form.(%{
            "ask" => %{"goal" => "g", "site_url" => "authz-odd.example", "tools" => "x"},
            "step" => "preview"
          })
        ),
        status_row(
          "form: previewed is a list",
          fine,
          form.(%{
            "ask" => %{"goal" => "g", "site_url" => "authz-odd.example"},
            "step" => "post",
            "previewed" => ["x"]
          })
        ),
        status_row("reply form: reply is text", fine, fn ->
          as(a) |> post("/posts/#{thread.id}/replies", %{"reply" => "text"})
        end),
        status_row("reply form: body is a list", fine, fn ->
          as(a)
          |> post("/threads/#{thread.id}/replies", %{"reply" => %{"body_markdown" => ["a"]}})
        end),
        status_row("reply form: null byte", fine, fn ->
          as(a)
          |> post("/threads/#{thread.id}/replies", %{"reply" => %{"body_markdown" => "a\u0000b"}})
        end),
        status_row("reply form: thread id is not an id", [404 | refused], fn ->
          as(a) |> post("/threads/not-an-id/replies", %{"reply" => %{"body_markdown" => "a"}})
        end),
        status_row("follow: follow is neither true nor false", refused, fn ->
          as(a) |> post(~p"/follow", %{"site_id" => thread.site_id, "follow" => "maybe"})
        end),
        status_row("follow: site id is not an id", fine, fn ->
          as(a) |> post(~p"/follow", %{"site_id" => "not-an-id", "follow" => "true"})
        end),
        status_row("follow: site id is a list", fine, fn ->
          as(a) |> post(~p"/follow", %{"site_id" => ["x"], "follow" => "true"})
        end),
        status_row("solution: reply id is not an id", fine, fn ->
          as(a) |> post("/posts/#{thread.id}/solution", %{"reply_id" => "not-an-id"})
        end),
        status_row("like: reply id is not an id", fine, fn ->
          as(a)
          |> post("/posts/#{thread.id}/likes", %{"like" => "true", "reply_id" => "not-an-id"})
        end),
        status_row(
          "API thread: 9 MB JSON",
          [413],
          api.("/forum/threads", Jason.encode!(%{"title" => big}))
        ),
        status_row("API thread: malformed JSON", refused, api.("/forum/threads", "{\"title\":")),
        status_row(
          "API thread: invalid UTF-8",
          refused,
          api.("/forum/threads", <<"{\"title\":\"", 0xFF, 0xFE, "\"}">>)
        ),
        status_row("API thread: top-level array", refused, api.("/forum/threads", "[1,2]")),
        status_row(
          "API thread: wrong types",
          refused,
          api.(
            "/forum/threads",
            Jason.encode!(%{
              "site" => [],
              "title" => 123,
              "body_markdown" => %{},
              "tools" => "x",
              "topic_tags" => [1],
              "client_request_id" => Ecto.UUID.generate()
            })
          )
        ),
        status_row(
          "API thread: request key is a number",
          refused,
          api.(
            "/forum/threads",
            Jason.encode!(%{"site" => @site, "title" => "t", "client_request_id" => 5})
          )
        ),
        status_row(
          "API thread: null bytes",
          [201 | refused],
          api.(
            "/forum/threads",
            Jason.encode!(%{
              "site" => @site,
              "title" => "authz \u0000 api",
              "body_markdown" => "b\u0000",
              "client_request_id" => Ecto.UUID.generate()
            })
          )
        ),
        status_row(
          "API thread: odd unicode",
          [201 | refused],
          api.(
            "/forum/threads",
            Jason.encode!(%{
              "site" => @site,
              "title" => odd,
              "body_markdown" => odd,
              "client_request_id" => Ecto.UUID.generate()
            })
          )
        ),
        status_row(
          "API thread: thread kind is a number",
          refused,
          api.(
            "/forum/threads",
            Jason.encode!(%{
              "site" => @site,
              "title" => "t",
              "thread_kind" => 7,
              "client_request_id" => Ecto.UUID.generate()
            })
          )
        ),
        status_row(
          "API reply: body is a number",
          refused,
          api.(
            "/forum/threads/#{thread.id}/replies",
            Jason.encode!(%{"body_markdown" => 5, "client_request_id" => Ecto.UUID.generate()})
          )
        ),
        status_row(
          "API reply: thread id is not an id",
          [404 | refused],
          api.(
            "/forum/threads/not-an-id/replies",
            Jason.encode!(%{"body_markdown" => "a", "client_request_id" => Ecto.UUID.generate()})
          )
        ),
        status_row(
          "API reply: null byte",
          [201 | refused],
          api.(
            "/forum/threads/#{thread.id}/replies",
            Jason.encode!(%{
              "body_markdown" => "a\u0000b",
              "client_request_id" => Ecto.UUID.generate()
            })
          )
        ),
        status_row(
          "API solution: reply id is a number",
          [403, 404 | refused],
          api.("/forum/threads/#{thread.id}/solution", Jason.encode!(%{"reply_id" => 5}))
        ),
        status_row(
          "API follow: site is a number",
          refused,
          api.("/forum/subscriptions", Jason.encode!(%{"site" => 5}))
        ),
        status_row(
          "API follow: thread id is not an id",
          [404 | refused],
          api.("/forum/subscriptions", Jason.encode!(%{"thread_id" => "nope"}))
        ),
        status_row(
          "API Credits history: cursor is a number",
          refused,
          api.("/tools/account/credits/history", Jason.encode!(%{"after" => 5}))
        ),
        status_row(
          "API pairing: code is a number",
          refused,
          api.(
            "/api/agents/v1/pair",
            Jason.encode!(%{"code" => 1, "name" => "n", "harness" => "codex"})
          )
        ),
        status_row("API search: query is a list", [200 | refused], fn ->
          get(build_conn(), "/forum/search", %{"q" => ["x", "y"]})
        end),
        status_row("API thread read: id is not an id", [404 | refused], fn ->
          get(build_conn(), "/forum/threads/not-an-id")
        end),
        status_row(
          "API agent name: name is a map",
          refused,
          api.("/forum/agent-name", Jason.encode!(%{"agent_name" => %{"x" => 1}}))
        )
      ]

      judge("input handling", rows)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Redirects stay on this site

  # Where a browser would go for a Location header: nowhere else, if the
  # address is a path on this site.
  defp same_site?(location) when is_binary(location) do
    uri = URI.parse(location)

    Phoenix.URL.classify_local_path(location) == :ok and is_nil(uri.host) and
      is_nil(uri.scheme) and not String.contains?(location, ["\\", "\t", "\r", "\n"])
  end

  defp same_site?(_location), do: false

  defp redirect_row(label, fun) do
    {status, conn} = outcome(fun)

    location =
      if is_struct(conn, Plug.Conn), do: get_resp_header(conn, "location") |> List.first()

    ok? =
      (status in [301, 302, 303] and same_site?(location)) or
        (status in [400, 404, 422] and is_nil(location))

    {label, ok?, "a redirect to a path on this site, or a 4xx refusal", {status, location}}
  end

  describe "7. redirects only go to same-site paths" do
    test "the follow form's way back", %{a: a} do
      site = site!()

      backs = [
        "https://evil.example/x",
        "http:evil.example",
        "//evil.example",
        "///evil.example",
        "/\\evil.example",
        "\\\\evil.example",
        "/\\/evil.example",
        "/%09/evil.example",
        "/\t/evil.example",
        " //evil.example",
        "javascript:alert(1)",
        "/%2F%2Fevil.example",
        "/\r\nlocation: https://evil.example",
        "/account/inbox"
      ]

      follow_rows =
        for back <- backs do
          redirect_row("follow back=#{inspect(back)}", fn ->
            as(a)
            |> post(~p"/follow", %{"site_id" => site.id, "follow" => "true", "back" => back})
          end)
        end

      # The same addresses percent-encoded in the form body, as a browser sends them.
      encoded_rows =
        for back <- ["%2F%2Fevil.example", "%2F%5Cevil.example", "https%3A%2F%2Fevil.example"] do
          redirect_row("follow back sent encoded #{back}", fn ->
            as(a)
            |> raw(
              ~p"/follow",
              "application/x-www-form-urlencoded",
              "site_id=#{site.id}&follow=true&back=#{back}"
            )
          end)
        end

      judge("follow redirects", follow_rows ++ encoded_rows)
    end

    test "a like's way back to the post", %{a: a} do
      thread = thread!(a)

      like_rows =
        for reply_id <- [
              "\\evil.example",
              "/\\evil.example",
              "x\r\nlocation: https://evil.example"
            ] do
          redirect_row("like reply_id=#{inspect(reply_id)}", fn ->
            as(a)
            |> post("/posts/#{thread.id}/likes", %{"like" => "true", "reply_id" => reply_id})
          end)
        end

      judge("like redirects", like_rows)
    end

    test "the sign-in consent page", %{a: a} do
      oauth_rows =
        for redirect_uri <- ["https://evil.example/cb", "//evil.example/cb"] do
          {status, conn} =
            outcome(fn ->
              as(a)
              |> get("/oauth/authorize", %{
                "response_type" => "code",
                "client_id" => Ecto.UUID.generate(),
                "redirect_uri" => redirect_uri,
                "state" => "s",
                "code_challenge" => String.duplicate("a", 43),
                "code_challenge_method" => "S256"
              })
            end)

          location =
            if is_struct(conn, Plug.Conn), do: List.first(get_resp_header(conn, "location"))

          {"OAuth consent with an unregistered client and redirect_uri #{redirect_uri}",
           status in [400, 401, 404, 422] and is_nil(location), "a 4xx refusal and no redirect",
           {status, location}}
        end

      judge("consent redirects", oauth_rows)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. User text is escaped

  @script_title ~s|<script>alert("authz-title")</script><img src=x onerror=alert(1)>|
  @script_body ~s|<script>alert("authz-body")</script> [click](javascript:alert(2)) <img src=x onerror=alert(3)> <a href="javascript:alert(4)">a</a>|
  @link_title "authz md [click](javascript:alert(5))"

  # Markup a visitor wrote that would run or load if the page kept it: a
  # script, an image, an event handler attribute or a javascript: link.
  defp raw_markup(html) do
    document = LazyHTML.from_fragment(html)

    for {name, found?} <- [
          {"script tag", html =~ ~s(<script>alert("authz)},
          {"img tag", html =~ ~r/<img src=x/i},
          {"event handler attribute", not Enum.empty?(LazyHTML.query(document, "[onerror]"))},
          {"javascript: link",
           not Enum.empty?(LazyHTML.query(document, ~s(a[href^="javascript:" i])))}
        ],
        found?,
        do: name
  end

  describe "8. user text is escaped" do
    test "titles, tags, names and Markdown bodies render as text", %{a_agent: a_agent} do
      %{"thread_id" => id} =
        a_agent
        |> ask(@script_title, %{"body_markdown" => @script_body})
        |> json_response(201)

      %{"thread_id" => link_id} = a_agent |> ask(@link_title) |> json_response(201)
      link_report = Ash.get!(Report, link_id)
      link_path = PostAddress.path(link_report)

      tag = a_agent |> ask("authz tag check", %{"topic_tags" => ["<b>x</b>"]})
      name = a_agent |> post_json("/forum/agent-name", %{"agent_name" => "<b>n</b>"})

      escaped = "&lt;script&gt;alert(&quot;authz-title&quot;)&lt;/script&gt;"
      site_page = get(as(nil), "/" <> @site).resp_body
      post_path = PostAddress.path(Ash.get!(Report, id))
      post_page = get(as(nil), post_path).resp_body

      {:ok, view, _html} =
        live_isolated(build_conn(), PatchbayWeb.SearchLive,
          session: %{
            "visitor" => "authz-visitor-" <> Ash.UUID.generate(),
            "site_edition" => :main
          }
        )

      render_hook(view, "open", %{"recent" => []})
      render_async(view)
      view |> form("#shell-search-form", %{"q" => "alert"}) |> render_change()
      search = render_async(view)

      markdown_conn =
        build_conn() |> put_req_header("accept", "text/markdown") |> get(post_path)

      site_markdown =
        build_conn() |> put_req_header("accept", "text/markdown") |> get("/" <> @site)

      rows = [
        {"a tag with markup", tag.status == 422, "refused (422)", tag.status},
        {"a name with markup", name.status == 422, "refused (422)", name.status},
        {"site page: raw markup", raw_markup(site_page) == [], "none", raw_markup(site_page)},
        {"site page: escaped title", site_page =~ escaped, "present", site_page =~ escaped},
        {"post page: raw markup", raw_markup(post_page) == [], "none", raw_markup(post_page)},
        {"post page: escaped title", post_page =~ escaped, "present", post_page =~ escaped},
        {"search results: raw markup", raw_markup(search) == [], "none", raw_markup(search)},
        {"search results: escaped title", search =~ "&lt;script&gt;", "present",
         search =~ "&lt;script&gt;"},
        {"post as Markdown: served as Markdown, never sniffed as a page",
         markdown_headers(markdown_conn) == {"text/markdown", "nosniff"},
         ~s({"text/markdown", "nosniff"}), markdown_headers(markdown_conn)},
        {"site page as Markdown, rendered: the title stays the words of its own link",
         markdown_links(site_markdown.resp_body, link_path) == {[], true},
         "no javascript: link, and every link to the post is its whole title",
         markdown_links(site_markdown.resp_body, link_path)}
      ]

      judge("escaping", rows)
      assert link_report.title == @link_title
    end
  end

  # The links a Markdown reader that keeps every address would draw: any
  # javascript: link, and whether every link to the post carries its whole title.
  defp markdown_links(markdown, path) do
    html = MDEx.to_html!(markdown, render: [unsafe: true])
    document = LazyHTML.from_fragment(html)
    scripted = document |> LazyHTML.query(~s(a[href^="javascript:" i])) |> LazyHTML.text()
    own = document |> LazyHTML.query(~s(a[href="#{path}"])) |> Enum.map(&LazyHTML.text/1)

    {List.wrap(if(scripted != "", do: scripted)),
     own != [] and Enum.all?(own, &(&1 == @link_title))}
  end

  defp markdown_headers(conn) do
    type = conn |> get_resp_header("content-type") |> List.first("") |> String.split(";") |> hd()
    {type, conn |> get_resp_header("x-content-type-options") |> List.first()}
  end

  # Reads every follow row, whoever owns it, to see what a request really saved.
  defp site_follows(principal) do
    Forum.Subscription
    |> Ash.Query.filter(principal == ^principal and scope_kind == :site)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.scope_id)
  end

  defp redact_as(record, actor) do
    record
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: :redacted}, actor: actor)
    |> Ash.update()
    |> refusal_kind()
  end

  defp refusal_kind({:error, %Ash.Error.Forbidden{}}), do: :forbidden
  defp refusal_kind(other), do: other

  defp without_flash({:error, {:redirect, %{to: to}}}), do: {:error, {:redirect, %{to: to}}}
  defp without_flash({:error, {:live_redirect, %{to: to}}}), do: {:error, {:redirect, %{to: to}}}
  defp without_flash(other), do: other
end
