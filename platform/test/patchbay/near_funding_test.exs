defmodule Patchbay.NearFundingTest do
  @moduledoc """
  A funding from start to its last state: the quote it keeps, the wallet the
  USDC goes to (always the paired agent's own, whatever the request says),
  the refund account it accepts, and the status job, which follows the swap
  to Arrived, Refunded or Failed and then stops.
  """

  use PatchbayWeb.ConnCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  import Phoenix.LiveViewTest

  alias Patchbay.NearFunding
  alias Patchbay.NearFunding.Funding
  alias PatchbayWeb.SignedAgent

  @fixtures Path.expand("../support/near_intents", __DIR__)

  setup do
    test = self()

    Req.Test.stub(RegentNearIntents, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:quote_asked, Jason.decode!(body)})
      Req.Test.json(conn, live_quote())
    end)

    %{agent: SignedAgent.pair!()}
  end

  test "the USDC goes to the agent's own wallet, never one the request names", %{agent: agent} do
    other = "0x" <> String.duplicate("9", 40)

    assert {:ok, funding} =
             NearFunding.start(person(agent), agent.pairing, %{
               "amount_usdc" => "5.00",
               "refund_to" => "alice.near",
               "recipient" => other
             })

    assert_received {:quote_asked, asked}
    assert asked["recipient"] == agent.wallet
    assert asked["amount"] == "5000000"
    assert funding.recipient == agent.wallet
    assert funding.pairing_id == agent.pairing.id

    assert %{state: :pending_deposit, usdc_amount: 5_000_000} = funding
    assert funding.near_amount == "1.651313840569386417635746"
    assert funding.quote["quote"]["depositAddress"] == funding.deposit_address

    # The record itself takes no recipient but the one it was started with.
    assert {:error, %Ash.Error.Invalid{}} =
             NearFunding.record_funding_status(funding, %{recipient: other}, authorize?: false)
  end

  test "the refund account must be a NEAR account", %{agent: agent} do
    for account <- ["Alice.near", "alice near", "0xabc!", "a", "", "alice..near"] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               NearFunding.start(person(agent), agent.pairing, %{
                 "amount_usdc" => "5",
                 "refund_to" => account
               })

      assert Enum.any?(errors, &(&1.field == :refund_to)), account
      refute_received {:quote_asked, _asked}
    end

    for account <- ["alice.near", "bob_1.tg", "sub.alice.near", String.duplicate("ab", 32)] do
      assert {:ok, _funding} =
               NearFunding.start(person(agent), agent.pairing, %{
                 "amount_usdc" => "1",
                 "refund_to" => account
               }),
             account
    end

    assert {:error, %Ash.Error.Invalid{}} =
             NearFunding.start(person(agent), agent.pairing, %{
               "amount_usdc" => "nope",
               "refund_to" => "a.near"
             })
  end

  test "a person reads only their own fundings, and an agent is funded only by its own person",
       %{agent: agent} do
    {:ok, funding} =
      NearFunding.start(person(agent), agent.pairing, %{
        "amount_usdc" => "5",
        "refund_to" => "alice.near"
      })

    stranger = SignedAgent.pair!()

    assert NearFunding.latest_funding!(actor: person(agent)).id == funding.id
    assert NearFunding.latest_funding!(actor: person(stranger)) == nil
    assert {:error, _not_theirs} = NearFunding.get_funding(funding.id, actor: person(stranger))

    assert_raise FunctionClauseError, fn ->
      NearFunding.start(person(stranger), agent.pairing, %{
        "amount_usdc" => "5",
        "refund_to" => "a.near"
      })
    end
  end

  test "a quote the service refuses writes nothing", %{agent: agent} do
    Req.Test.stub(RegentNearIntents, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{message: "Amount is too low"})
    end)

    assert {:error, %Ash.Error.Invalid{}} =
             NearFunding.start(person(agent), agent.pairing, %{
               "amount_usdc" => "5",
               "refund_to" => "alice.near"
             })

    assert Ash.read!(Funding, authorize?: false) == []
  end

  test "the status job follows the swap to each last state, then stops", %{agent: agent} do
    for {status, state} <- [{"SUCCESS", :success}, {"REFUNDED", :refunded}, {"FAILED", :failed}] do
      Req.Test.stub(RegentNearIntents, &Req.Test.json(&1, live_quote()))

      {:ok, funding} =
        NearFunding.start(person(agent), agent.pairing, %{
          "amount_usdc" => "5",
          "refund_to" => "alice.near"
        })

      Phoenix.PubSub.subscribe(Patchbay.PubSub, "near_funding:" <> funding.id)

      stub_status("PROCESSING", [], [])
      assert %{success: 2, failure: 0} = schedule_and_run_triggers({Funding, :refresh})
      assert %{state: :processing} = NearFunding.get_funding!(funding.id, authorize?: false)

      stub_status(status, [tx("near-tx")], [tx("0xbase")])
      assert %{success: 2, failure: 0} = schedule_and_run_triggers({Funding, :refresh})

      assert %{state: ^state, origin_tx: "near-tx", destination_tx: "0xbase"} =
               NearFunding.get_funding!(funding.id, authorize?: false)

      assert_received %Ash.Notifier.Notification{data: %Funding{state: ^state}}

      # A funding at its last state is never read again.
      Req.Test.stub(RegentNearIntents, fn _conn -> flunk("read after #{state}") end)
      assert %{success: 1, failure: 0} = schedule_and_run_triggers({Funding, :refresh})
    end
  end

  test "a read the service could not answer is tried again, and the funding waits", %{
    agent: agent
  } do
    {:ok, funding} =
      NearFunding.start(person(agent), agent.pairing, %{
        "amount_usdc" => "5",
        "refund_to" => "alice.near"
      })

    Req.Test.stub(RegentNearIntents, &Plug.Conn.send_resp(&1, 503, ""))
    assert %{failure: 1} = schedule_and_run_triggers({Funding, :refresh})
    assert %{state: :pending_deposit} = NearFunding.get_funding!(funding.id, authorize?: false)
  end

  describe "the Agents page" do
    setup do
      original = Application.get_env(:patchbay, :near_funding_enabled?)
      on_exit(fn -> Application.put_env(:patchbay, :near_funding_enabled?, original) end)
      :ok
    end

    test "shows a price and the address to send NEAR to, then the swap's progress", %{
      conn: conn,
      agent: agent
    } do
      Application.put_env(:patchbay, :near_funding_enabled?, true)
      conn = sign_in(conn, agent.owner.id)

      {:ok, view, _html} = live(conn, ~p"/account/agents")
      assert has_element?(view, "#near-funding-form button", "Fund with NEAR")
      # The panel has no field for where the USDC goes.
      refute has_element?(view, "#near-funding-form [name=recipient]")

      view
      |> form("#near-funding-form", %{
        "agent_id" => agent.pairing.id,
        "amount_usdc" => "5.00",
        "refund_to" => "alice.near"
      })
      |> render_submit()

      assert_received {:quote_asked, %{"recipient" => wallet}}
      assert wallet == agent.wallet

      assert has_element?(view, "#near-funding-price", "1.651314 NEAR")
      [funding] = Ash.read!(Funding, authorize?: false)
      assert has_element?(view, "#near-funding-deposit", funding.deposit_address)
      assert has_element?(view, "#near-funding-wallet-copy[data-copy-text='#{agent.wallet}']")
      assert has_element?(view, "#near-funding-status", "Waiting")

      stub_status("SUCCESS", [tx("near-tx")], [tx("0x" <> String.duplicate("b", 64))])
      assert %{success: 2, failure: 0} = schedule_and_run_triggers({Funding, :refresh})

      assert has_element?(view, "#near-funding-status", "Arrived")

      assert has_element?(
               view,
               "#near-funding-origin-tx[href='https://nearblocks.io/txns/near-tx']"
             )

      assert has_element?(view, "#near-funding-destination-tx")

      # The panel opened again shows the newest funding, and Fund again starts another.
      {:ok, view, _html} = live(conn, ~p"/account/agents")
      assert has_element?(view, "#near-funding-status", "Arrived")
      view |> element("#near-funding-funding button", "Fund again") |> render_click()
      assert has_element?(view, "#near-funding-form")
    end

    test "a deposit address that closed with nothing sent reads as expired", %{
      conn: conn,
      agent: agent
    } do
      Application.put_env(:patchbay, :near_funding_enabled?, true)

      Req.Test.stub(RegentNearIntents, fn conn ->
        Req.Test.json(
          conn,
          put_in(live_quote(), ["quote", "deadline"], "2026-01-01T00:00:00.000Z")
        )
      end)

      {:ok, _funding} =
        NearFunding.start(person(agent), agent.pairing, %{
          "amount_usdc" => "5",
          "refund_to" => "alice.near"
        })

      {:ok, view, _html} = live(sign_in(conn, agent.owner.id), ~p"/account/agents")
      assert has_element?(view, "#near-funding-status", "Expired")

      # Nothing more is read for it.
      Req.Test.stub(RegentNearIntents, fn _conn -> flunk("read an expired funding") end)
      assert %{success: 1, failure: 0} = schedule_and_run_triggers({Funding, :refresh})
    end

    test "an empty or wrong refund account is refused on the page, and nothing is asked", %{
      conn: conn,
      agent: agent
    } do
      Application.put_env(:patchbay, :near_funding_enabled?, true)
      {:ok, view, _html} = live(sign_in(conn, agent.owner.id), ~p"/account/agents")

      view
      |> form("#near-funding-form", %{
        "agent_id" => agent.pairing.id,
        "amount_usdc" => "5",
        "refund_to" => "Not An Account"
      })
      |> render_submit()

      refute_received {:quote_asked, _asked}
      assert has_element?(view, "#near-funding-refund-errors p")
      refute has_element?(view, "#near-funding-funding")
    end

    test "another person's agent cannot be funded from this page", %{conn: conn, agent: agent} do
      Application.put_env(:patchbay, :near_funding_enabled?, true)
      stranger = SignedAgent.pair!()
      {:ok, view, _html} = live(sign_in(conn, agent.owner.id), ~p"/account/agents")

      render_submit(view |> element("#near-funding-form"), %{
        "agent_id" => stranger.pairing.id,
        "amount_usdc" => "5",
        "refund_to" => "alice.near"
      })

      refute_received {:quote_asked, _asked}
      assert Ash.read!(Funding, authorize?: false) == []
    end

    test "has no panel while switched off, or at the open address", %{conn: conn, agent: agent} do
      Application.put_env(:patchbay, :near_funding_enabled?, false)
      {:ok, view, _html} = live(sign_in(conn, agent.owner.id), ~p"/account/agents")
      refute has_element?(view, "#near-funding")

      Application.put_env(:patchbay, :near_funding_enabled?, true)

      {:ok, view, _html} =
        live(sign_in(on_open(build_conn()), agent.owner.id), ~p"/account/agents")

      refute has_element?(view, "#near-funding")
    end
  end

  defp live_quote do
    @fixtures
    |> Path.join("quote_dry.json")
    |> File.read!()
    |> Jason.decode!()
    |> put_in(["quoteRequest", "dry"], false)
    |> put_in(
      ["quote", "depositAddress"],
      Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    )
    |> put_in(["quote", "deadline"], DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600)))
  end

  defp person(agent), do: %RegentAgents.Person{privy_user_id: agent.owner.privy_user_id}

  defp tx(hash), do: %{"hash" => hash, "explorerUrl" => "https://example.com/" <> hash}

  defp stub_status(status, origin, destination) do
    Req.Test.stub(RegentNearIntents, fn conn ->
      Req.Test.json(conn, %{
        "correlationId" => "c",
        "quoteResponse" => live_quote(),
        "status" => status,
        "updatedAt" => DateTime.to_iso8601(DateTime.utc_now()),
        "swapDetails" => %{
          "intentHashes" => [],
          "nearTxHashes" => [],
          "originChainTxHashes" => origin,
          "destinationChainTxHashes" => destination
        }
      })
    end)
  end
end
