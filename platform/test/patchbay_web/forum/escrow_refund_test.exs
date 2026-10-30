defmodule PatchbayWeb.Forum.EscrowRefundTest do
  @moduledoc """
  Taking a bounty back off the board.

  The escrow contract owns this rule: it refuses a refund until thirty days
  after the money was recorded and then lets anybody make one, paying the asker
  90% and the treasury 10%. Patchbay only relays and then watches. So what is
  tested here is that the board never decides in the chain's place, never
  refuses a press on account of the money's state, and writes down what it
  finds. No escrow is configured in a test run, so every relay reaches an
  unreachable chain, which is exactly the shape of a chain that says no.
  """

  use PatchbayWeb.ConnCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Forum.RefundRelayRecord
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @contract String.duplicate("e", 64)
  @arguments String.duplicate("f", 64)
  @refund_tx "0x" <> String.duplicate("f", 64)
  # What the synthetic Base node answers: every transaction is taken.
  @base_node %{
    "eth_chainId" => "0x7a69",
    "eth_getTransactionCount" => "0x0",
    "eth_estimateGas" => "0x186a0",
    "eth_gasPrice" => "0x3b9aca00",
    "eth_maxPriorityFeePerGas" => "0x1",
    "eth_feeHistory" => %{
      oldestBlock: "0x0",
      baseFeePerGas: ["0x1", "0x1"],
      gasUsedRatio: [0.5],
      reward: [["0x1"]]
    },
    "eth_sendRawTransaction" => @refund_tx
  }

  setup do
    site = Forum.register_site!("shop.example.com")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: @contract
      })

    %{site: site, tool: tool}
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id)
  end

  defp paid_report(tool, asker) do
    Forum.file_priority_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: "The cart never changed.",
        priority_amount_atomic: 5_000_000,
        payment_intent_id: Ash.UUID.generate()
      },
      actor: asker
    )
  end

  defp credited(tool, asker, funded_at \\ DateTime.utc_now()) do
    # Recording what the escrow said is the settlement path's own write, which
    # no actor may reach, so the setup writes it the way that path does.
    {:ok, submitted} =
      Forum.record_escrow_credit(
        paid_report(tool, asker),
        %{
          escrow_status: :credit_submitted,
          escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)
        },
        authorize?: false
      )

    {:ok, report} =
      Forum.confirm_escrow_credit(submitted, %{escrow_funded_at: funded_at}, authorize?: false)

    report
  end

  defp priority_ids(versions) do
    versions
    |> Forum.list_priority_reports_for_tools!()
    |> Map.fetch!(:results)
    |> Enum.map(& &1.id)
  end

  defp ordinary_ids(versions) do
    versions |> Forum.list_reports_for_tools!() |> Map.fetch!(:results) |> Enum.map(& &1.id)
  end

  defp free_report(tool) do
    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    Forum.file_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure
      },
      authorize?: false
    )
  end

  describe "a refund Base takes" do
    setup do
      old_escrow = Application.get_env(:patchbay, :escrow)

      # Synthetic operator key, generated for this run. It never reaches a real chain.
      Application.put_env(:patchbay, :escrow,
        contract_address: "0x" <> String.duplicate("c", 40),
        operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        rpc_url: base_node()
      )

      on_exit(fn -> Application.put_env(:patchbay, :escrow, old_escrow) end)
    end

    test "says the money went back, with its transaction, and writes it down after", %{
      conn: conn,
      tool: tool
    } do
      asker = profile("aaa")
      report = credited(tool, asker)

      page =
        conn |> signed_in(asker) |> post("/posts/#{report.id}/refund", %{}) |> html_response(200)

      assert page =~ "The asker took this money back: 90% went back to their wallet"
      assert page =~ ~s(href="https://basescan.org/tx/#{@refund_tx}")
      refute page =~ "could not be taken back"

      # Base accepting it is the refund; writing it down is the job's.
      assert_enqueued(
        worker: RefundRelayRecord,
        args: %{report_id: report.id, tx_hash: @refund_tx}
      )

      assert is_nil(Forum.get_report!(report.id).escrow_refund_tx_hash)

      assert :ok =
               perform_job(RefundRelayRecord, %{report_id: report.id, tx_hash: @refund_tx})

      assert Forum.get_report!(report.id).escrow_refund_tx_hash == @refund_tx
    end

    test "says the money went back when the post is then too busy to read", %{
      conn: conn,
      tool: tool
    } do
      asker = profile("aaa")
      report = credited(tool, asker)
      hold_the_connection_once_the_record_is_queued()

      # Asked from another process, as a visitor's request is, so the sandbox
      # drops its wait from the queue as it would a crowd's.
      refunded =
        fn -> conn |> signed_in(asker) |> post("/posts/#{report.id}/refund", %{}) end
        |> Task.async()
        |> Task.await(30_000)

      assert_received {:holder, holder}
      send(holder, :release)

      html = html_response(refunded, 503)

      assert html =~
               "Your money went back: Base accepted the refund, transaction #{@refund_tx}. " <>
                 "This page could not refresh to show it."

      assert html =~ ~s(href="/posts/#{report.id}")
      assert get_resp_header(refunded, "retry-after") == ["2"]

      assert_enqueued(
        worker: RefundRelayRecord,
        args: %{report_id: report.id, tx_hash: @refund_tx}
      )
    end

    test "an agent's page session is told the refund was asked, with its transaction", %{
      conn: conn,
      tool: tool
    } do
      asker = profile("aaa")
      report = credited(tool, asker)

      answer =
        conn
        |> signed_in(asker)
        |> post(~p"/forum/reports/#{report.id}/refund")
        |> json_response(200)

      assert answer["asked"] == true
      assert answer["refund_tx_hash"] == @refund_tx

      assert_enqueued(
        worker: RefundRelayRecord,
        args: %{report_id: report.id, tx_hash: @refund_tx}
      )
    end

    test "a record the database is too busy for is tried again", %{tool: tool} do
      report = credited(tool, profile("aaa"))
      test = self()

      holder =
        spawn(fn ->
          Patchbay.Repo.transaction(
            fn ->
              send(test, :held)
              receive do: (:release -> :ok)
            end,
            timeout: :infinity
          )
        end)

      assert_receive :held

      # Asked from another process, as the queue's own runner is, so the
      # sandbox drops its wait as it would under load.
      answer =
        fn -> perform_job(RefundRelayRecord, %{report_id: report.id, tx_hash: @refund_tx}) end
        |> Task.async()
        |> Task.await(30_000)

      send(holder, :release)

      assert {:error, _busy} = answer
      assert is_nil(Forum.get_report!(report.id).escrow_refund_tx_hash)
    end
  end

  # Once the refund Base took is queued to be written down, another process
  # takes the test's one database connection, so the post's next read waits in
  # the queue until the sandbox drops it.
  defp hold_the_connection_once_the_record_is_queued do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if record_queued?(query) and is_nil(Process.get(id)) do
          holder = spawn(&hold_until_released/0)
          Process.put(id, holder)
          send(test, {:holder, holder})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # It holds until released, however long the refund's own steps took.
  defp hold_until_released do
    Patchbay.Repo.transaction(fn -> receive do: (:release -> :ok) end, timeout: :infinity)
  end

  defp record_queued?(~s(INSERT INTO "public"."oban_jobs") <> _job), do: true
  defp record_queued?(_query), do: false

  defp base_node do
    server =
      start_supervised!(
        {Bandit,
         plug: fn conn, _options ->
           {:ok, raw, conn} = Plug.Conn.read_body(conn)

           conn
           |> Plug.Conn.put_resp_content_type("application/json")
           |> Plug.Conn.send_resp(200, raw |> Jason.decode!() |> rpc() |> Jason.encode!())
         end,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp rpc(requests) when is_list(requests), do: Enum.map(requests, &rpc/1)

  defp rpc(%{"id" => id, "method" => method}),
    do: %{jsonrpc: "2.0", id: id, result: Map.fetch!(@base_node, method)}

  describe "what the board decides" do
    test "a chain that will not take the request leaves the money held", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      assert {:ok, refused} = PriorityRefund.run(report.id, asker)
      assert refused.escrow_status == :refund_failed
      assert is_nil(refused.escrow_refund_tx_hash)
      assert refused.refund_requested_at
    end

    test "a press before Base has confirmed the bounty leaves it waiting", %{tool: tool} do
      asker = profile("aaa")

      # The settlement path's own write, which no actor may reach.
      {:ok, submitted} =
        Forum.record_escrow_credit(
          paid_report(tool, asker),
          %{
            escrow_status: :credit_submitted,
            escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)
          },
          authorize?: false
        )

      # The press reaches the chain and is refused; the refusal is not written
      # over the waiting record, so the confirmation can still be written down.
      assert {:ok, pressed} = PriorityRefund.run(submitted.id, asker)
      assert pressed.escrow_status == :credit_submitted
      assert pressed.refund_requested_at

      assert {:ok, confirmed} =
               Forum.confirm_escrow_credit(pressed, %{escrow_funded_at: DateTime.utc_now()},
                 authorize?: false
               )

      assert confirmed.escrow_status == :credited
    end

    test "nothing about the money's state stops the next press", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      {:ok, first} = PriorityRefund.run(report.id, asker)

      # A press while an earlier one is in flight, and a press after one the
      # chain refused, both reach the chain again. The board never holds a
      # press back on account of what it believes about the money.
      assert {:ok, second} = PriorityRefund.run(report.id, asker)
      assert DateTime.compare(second.refund_requested_at, first.refund_requested_at) in [:gt, :eq]
      assert {:ok, _third} = PriorityRefund.run(report.id, asker)
    end

    test "only the asker can spend Patchbay's gas on it", %{tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, stranger)
      assert {:error, %Ash.Error.Forbidden{}} = PriorityRefund.run(report.id, nil)

      {:ok, untouched} = Forum.get_report(report.id)
      assert untouched.escrow_status == :credited
      assert is_nil(untouched.refund_requested_at)
    end

    test "a report nobody paid for has nothing to take back", %{tool: tool} do
      asker = profile("aaa")

      unpaid =
        Forum.file_report!(
          %{
            tool_id: tool.id,
            browser_session_id: Ash.UUID.generate(),
            arguments_sha256: @arguments,
            verdict: :verified_failure
          },
          actor: asker
        )

      assert {:error, %Ash.Error.Invalid{} = refused} = PriorityRefund.run(unpaid.id, asker)
      assert Exception.message(refused) =~ "no money behind it"
    end

    test "a bounty that went back cannot then be awarded to an answer", %{tool: tool} do
      asker = profile("aaa")
      answerer = profile("bbb")
      report = credited(tool, asker)

      {:ok, reply} =
        Forum.add_reply(
          %{
            report_id: report.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :verified_failure,
            note: "Same here."
          },
          actor: answerer
        )

      # Moderation's word is nobody's to give over HTTP either.
      {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)

      {:ok, refunded} = PriorityRefund.record(report, "0xdead")

      assert {:error, %Ash.Error.Invalid{} = refused} =
               Forum.accept_reply(refunded, reply.id, actor: asker)

      assert Exception.message(refused) =~ "gone back to its asker"
    end
  end

  describe "watching Base" do
    test "a refund found on Base moves the report out of the paid section", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      versions = [report.tool_id]

      assert priority_ids(versions) == [report.id]
      assert ordinary_ids(versions) == []

      {:ok, refunded} = PriorityRefund.record(report, "0x" <> String.duplicate("2", 64))
      assert refunded.escrow_status == :refunded
      assert refunded.escrow_refund_tx_hash == "0x" <> String.duplicate("2", 64)

      # A bounty that has gone back is an ordinary report again, and is listed
      # with them rather than among the ones still worth answering for money.
      assert priority_ids(versions) == []
      assert ordinary_ids(versions) == [report.id]
    end

    test "a sweep with no escrow configured reads nothing and changes nothing", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      assert %{failure: 0} = schedule_and_run_triggers({Forum.Report, :read_escrow_refund})

      {:ok, untouched} = Forum.get_report(report.id)
      assert untouched.escrow_status == :credited
    end

    test "the refund sweep asks about the bounties the board still believes are held", %{
      tool: tool
    } do
      asker = profile("aaa")
      held = credited(tool, asker)
      {:ok, gone} = PriorityRefund.record(credited(tool, profile("bbb")), "0xdead")
      free = free_report(tool)

      assert_would_schedule(held, :read_escrow_refund)
      refute_would_schedule(gone, :read_escrow_refund)
      refute_would_schedule(free, :read_escrow_refund)
    end
  end

  describe "over the board's tools" do
    test "the asker is told what was asked, not that the money moved", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      answer =
        conn
        |> signed_in(asker)
        |> post(~p"/forum/reports/#{report.id}/refund")
        |> json_response(200)

      assert answer["asked"] == false
      assert answer["escrow_status"] == "refund_failed"
      assert answer["refundable_after_days"] == 30
      assert answer["report_id"] == report.id
    end

    test "a stranger is refused and an unknown report is missing", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      stranger = profile("bbb")
      report = credited(tool, asker)

      refused = conn |> signed_in(stranger) |> post(~p"/forum/reports/#{report.id}/refund")
      assert json_response(refused, 403)["error"]["code"] == "forbidden"

      missing = conn |> signed_in(asker) |> post(~p"/forum/reports/#{Ash.UUID.generate()}/refund")
      assert json_response(missing, 404)["error"]["code"] == "not_found"
    end
  end

  describe "on the report page" do
    test "the money card says when Base will let it go", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      mine = conn |> signed_in(asker) |> get(PostAddress.path(report)) |> html_response(200)

      assert mine =~ "Take my money back"
      assert mine =~ "Base will not send this bounty back before"
      assert mine =~ "30 days after it was recorded"

      theirs = conn |> get(PostAddress.path(report)) |> html_response(200)
      refute theirs =~ "Take my money back"
      assert theirs =~ "5.00 USDC on this report"
    end

    test "an old bounty says the thirty days are up", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      old = DateTime.add(DateTime.utc_now(), -31, :day)
      report = credited(tool, asker, old)

      page = conn |> signed_in(asker) |> get(PostAddress.path(report)) |> html_response(200)

      assert page =~ "The 30 days are up"
      assert page =~ "Take my money back"
    end

    test "the control stays live after a request Base refused", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)

      page =
        conn
        |> signed_in(asker)
        |> post(~p"/reports/#{report.id}/refund")
        |> html_response(200)

      assert page =~ "Base would not take that request"
      # What the page believes about the money never decides whether the asker
      # can press again: the press goes to Base and Base answers.
      assert page =~ "Take my money back"

      {:ok, held} = Forum.get_report(report.id)
      assert held.escrow_status == :refund_failed
    end

    test "a refunded report shows where its money went", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      {:ok, refunded} = PriorityRefund.record(credited(tool, asker), "0xdead")

      page = conn |> get(PostAddress.path(refunded)) |> html_response(200)

      assert page =~ "This bounty was taken off the board"
      assert page =~ "90% of it went back to the asker"
    end

    test "a report with no money behind it says nothing about escrow", %{conn: conn, tool: tool} do
      page = conn |> get(PostAddress.path(free_report(tool))) |> html_response(200)

      refute page =~ "THE MONEY"
      refute page =~ "Take my money back"
    end
  end

  describe "an asker's bounty record" do
    test "counts what was offered and what was awarded", %{conn: conn, tool: tool} do
      asker = profile("aaa")
      answerer = profile("bbb")

      credited(tool, asker)
      credited(tool, asker)
      settled = credited(tool, asker)

      {:ok, reply} =
        Forum.add_reply(
          %{
            report_id: settled.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :verified_failure,
            note: "Try the other endpoint."
          },
          actor: answerer
        )

      # Moderation's word is nobody's to give over HTTP either.
      {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)
      {:ok, _accepted} = Forum.accept_reply(settled, reply.id, actor: asker)

      page = conn |> get(~p"/agents/#{asker.public_id}") |> html_response(200)
      assert page =~ "Bounties posted"
      assert page =~ "Answers accepted"

      # The same two numbers reach an agent deciding whether this is worth
      # answering, through the tool that reads a profile.
      body = conn |> get(~p"/api/agents/#{asker.public_id}") |> json_response(200)
      assert body["bounties_posted"] == 3
      assert body["answers_accepted"] == 1
    end
  end
end
