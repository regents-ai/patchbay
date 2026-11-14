defmodule PatchbayWeb.PointsLiveTest do
  @moduledoc """
  What a signed-in person gets from Points on the first render, with no wait:
  their own figures, their place, and their own row on the leaderboard beside
  other people shown by their names or wallets; and what their paired agent is
  answered. Points are awarded the way the library awards them, one event at a
  time, and the board every reader shares is then read once, as its producer
  reads it on notice. The board is held for the whole machine, so this file runs
  alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Points.Board
  alias Patchbay.SharedReading
  alias PatchbayWeb.SignedAgent
  alias RegentPoints.{Rules, Store}

  # Account activated is earned where the person's account is kept, never on
  # Patchbay: this stands in for that site's check, which Points asks again as it
  # awards, and which accepts the account it is asked about.
  defmodule AccountSite do
    def verify(_reference), do: {:ok, %{}}
  end

  # Base, while earning is open in a test: it gives no answer, so the bonus card
  # says the NFTs could not be checked and nothing leaves this machine.
  defmodule NoChain do
    def rpc(_chain, _method, _params), do: {:error, :unavailable}
  end

  setup do
    SignedAgent.stub_siwa()

    # Periods count from the program's start; with no rule approved, earning
    # stays off.
    previous =
      Keyword.take(Application.get_all_env(:regent_points), [
        :starts_at,
        :approved_rules,
        :adapters,
        :chain_client
      ])

    Application.put_env(:regent_points, :starts_at, ~U[2020-01-01 00:00:00Z])

    Application.put_env(
      :regent_points,
      :adapters,
      Map.put(previous[:adapters], "account.activated", AccountSite)
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
      SharedReading.delete(Board.key())
    end)

    agent = SignedAgent.pair!()
    other = SignedAgent.pair!()
    award!(agent.account.id)
    award!(other.account.id)
    assert :ok = Board.read()

    conn =
      build_conn()
      |> sign_in(agent.owner.id)

    %{conn: conn, agent: agent, other: other}
  end

  test "the first render carries the person's total, their place and their own row", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/points")

    assert has_element?(view, ~s(.pb-account-tabs a[href="/points"][aria-current="page"]))
    assert has_element?(view, "#points-total .rg-points-total__figure", "25")
    assert has_element?(view, "#points-total dl", "#1")

    # Two accounts level on points share first place; only the reader's row is marked.
    assert view |> element(~s(#points-board li[data-you="true"])) |> has_element?()

    assert html |> LazyHTML.from_document() |> LazyHTML.query("#points-board li") |> Enum.count() ==
             2

    refute html =~ "Loading"
  end

  # Every wallet is public: another person with no name shows by their wallet,
  # whose copy icon copies it in full. Nothing else about the account leaves it.
  test "a person with no name shows by their wallet, with its copy icon", %{
    conn: conn,
    other: other
  } do
    {:ok, _view, html} = live(conn, ~p"/points")

    copies =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#points-board li[data-you="false"] [data-copy-text]))
      |> LazyHTML.attribute("data-copy-text")

    assert other.owner.wallet_address in copies
    refute html =~ other.owner.privy_user_id
  end

  test "while earning is off, the page says so and reads no NFT bonus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/points")

    assert has_element?(view, "#points-todo", "Earning hasn’t opened yet.")
    refute has_element?(view, "#points-bonus [role=status]", "Checking")
  end

  # Before earning opens nothing on the list carries points, a count left, a
  # daily limit or today's count, so nothing reads as earning.
  test "every listed action shows under its site, in order, and what the account has is done",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/points")
    todo = todo(html)

    assert Enum.map(todo, &elem(&1, 0)) == Enum.map(Rules.groups(), & &1.site)

    for {{_site, items}, %{rules: rules}} <- Enum.zip(todo, Rules.groups()) do
      assert Enum.sort(Enum.map(items, & &1.label)) ==
               Enum.sort(Enum.map(rules, &Rules.label(&1["id"])))
    end

    items = Enum.flat_map(todo, &elem(&1, 1))
    refute Rules.label("template.first_agent_note") in Enum.map(items, & &1.label)

    # The one award the account has, counted once, is the one action done.
    assert for(%{done: true} = item <- items, do: item.label) == [
             Rules.label("account.activated")
           ]

    assert Enum.all?(items, &(&1.points == "" and &1.note == ""))
    refute has_element?(view, "#points-todo .rg-points-todo__left")
    refute has_element?(view, "#points-limit")
  end

  test "once earning opens, every action this site does not earn says so", %{
    conn: conn,
    agent: agent
  } do
    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -1, :day))

    Application.put_env(:regent_points, :approved_rules, [
      "patchbay.report_published",
      "patchbay.reply_published"
    ])

    Application.put_env(:regent_points, :chain_client, NoChain)

    {:ok, summary} =
      RegentPoints.summary(actor: %{role: :human, human_account_id: agent.account.id})

    {:ok, view, html} = live(conn, ~p"/points")
    items = Enum.flat_map(todo(html), &elem(&1, 1))

    not_here = for {id, %{here: false}} <- summary.done, do: Rules.label(id)
    assert [_, _] = for({id, %{here: true}} <- summary.done, do: id)

    assert Enum.sort(for %{note: "Not on this site"} = item <- items, do: item.label) ==
             Enum.sort(not_here)

    assert Enum.all?(items, &(&1.points != ""))
    assert has_element?(view, "#points-todo .rg-points-todo__left")
    assert has_element?(view, "#points-limit progress")
  end

  # A person's paired agent reads the same figures the page shows, and its copy
  # of the leaderboard carries a place, a name or wallet and a total for each row.
  test "a paired agent is answered with the page's figures", %{
    conn: conn,
    agent: agent,
    other: other
  } do
    {:ok, view, _html} = live(conn, ~p"/points")

    answer =
      build_conn()
      |> SignedAgent.sign(agent)
      |> get("/tools/account/points")
      |> json_response(200)

    assert has_element?(view, "#points-total .rg-points-total__figure", answer["points"])
    assert %{"points" => "25", "earned_today" => "25", "rank" => 1} = answer
    assert answer["note"] == "Earning Points is off on this site."
    assert length(answer["leaderboard"]) == 2

    for row <- answer["leaderboard"] do
      assert row |> Map.keys() |> Enum.sort() == ~w(ens_name name points rank wallet you)
    end

    assert %{"name" => nil, "ens_name" => nil, "you" => false} =
             Enum.find(answer["leaderboard"], &(&1["wallet"] == other.owner.wallet_address))
  end

  # The board is held for signed-in readers; a signed-out visitor gets none of it.
  test "a signed-out visitor is asked to sign in and gets nothing from the board", %{
    other: other
  } do
    {:ok, view, html} = live(build_conn(), ~p"/points")

    assert has_element?(view, "#points-signed-out")
    refute has_element?(view, "#points-total")
    refute has_element?(view, "#points-board")
    refute html =~ other.owner.wallet_address
  end

  # Where the page would show the board as not read, the agent gets no half answer.
  test "while the board is not read, the agent's whole answer is unavailable", %{agent: agent} do
    SharedReading.delete(Board.key())

    assert %{"error" => %{"code" => "unavailable"}} =
             build_conn()
             |> SignedAgent.sign(agent)
             |> get("/tools/account/points")
             |> json_response(503)
  end

  # The to-do list as the page draws it: each site's title with its actions, each
  # with its label, whether it is done, the words under it and its points.
  defp todo(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#points-todo .rg-points-todo__group")
    |> Enum.map(fn group ->
      {group |> LazyHTML.query("h3") |> LazyHTML.text(),
       group |> LazyHTML.query("li") |> Enum.map(&action/1)}
    end)
  end

  defp action(item) do
    %{
      label: item |> LazyHTML.query(".rg-points-todo__label > :first-child") |> LazyHTML.text(),
      done: LazyHTML.attribute(item, "data-done") == ["true"],
      note: item |> LazyHTML.query(".rg-points-todo__label small") |> LazyHTML.text(),
      points: item |> LazyHTML.query(".rg-points-todo__points") |> LazyHTML.text()
    }
  end

  # One "Account activated" award, recorded and settled as the library settles
  # every event; no earning switch is needed for the award itself.
  defp award!(account_id) do
    at = DateTime.utc_now()
    key = "points-page-#{account_id}"
    rule = Enum.find(Rules.catalog(), &(&1["id"] == "account.activated"))
    RegentPoints.open_account!(%{id: account_id}, actor: Store.system())

    event =
      RegentPoints.create_event!(
        %{
          program_id: Rules.program(),
          source_app: "patchbay",
          source_kind: "test",
          source_event_key: key,
          rule_id: rule["id"],
          account_id: account_id,
          actor_kind: "human",
          actor_id: to_string(account_id),
          source_action_at: at,
          qualified_at: at,
          evidence_ref: "test:" <> key,
          evidence: %{},
          rule_snapshot: Map.put(rule, "effective_at", DateTime.to_iso8601(at)),
          award_key: Store.digest({key, rule["id"]}),
          payload_digest: Store.digest(key)
        },
        actor: Store.system()
      )

    assert {:ok, %{status: :confirmed}} =
             RegentPoints.process_event(event.id, actor: Store.system())
  end
end
