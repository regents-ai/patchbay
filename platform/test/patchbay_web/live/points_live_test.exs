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
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent
  alias RegentPoints.{Rules, Store}

  setup do
    SignedAgent.stub_siwa()

    # Periods count from the program's start; with no rule approved, earning
    # stays off.
    starts_at = Application.get_env(:regent_points, :starts_at)
    Application.put_env(:regent_points, :starts_at, ~U[2020-01-01 00:00:00Z])

    on_exit(fn ->
      Application.put_env(:regent_points, :starts_at, starts_at)
      SharedReading.delete(Board.key())
    end)

    agent = SignedAgent.pair!()
    other = SignedAgent.pair!()
    award!(agent.account.id)
    award!(other.account.id)
    assert :ok = Board.read()

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(agent.owner.id, System.os_time(:second))

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
