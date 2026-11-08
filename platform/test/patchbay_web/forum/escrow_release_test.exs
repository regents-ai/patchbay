defmodule PatchbayWeb.Forum.EscrowReleaseTest do
  @moduledoc """
  A bounty's money from the accepted answer to its author's wallet.

  Accepting an answer queues the payout in the same transaction; a job hands
  it to Base and writes only that it was handed over; the watch of Base
  writes what the contract did. Every step names the states it may start
  from and is checked against the stored row, so a writer holding an older
  copy never puts one state over a later one, and the database itself keeps
  only the known states, on a report with a bounty. A synthetic Base node
  answers here: the contract's record of the post, the receipts of the
  transactions it has put in a block, and whether it takes a request.
  """

  use PatchbayWeb.ConnCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  alias Patchbay.Forum
  alias Patchbay.Forum.Report.Workers.SendEscrowRelease
  alias Patchbay.Forum.SolutionRefused
  alias Patchbay.Forum.Types.EscrowStatus
  alias Patchbay.Identity
  alias Patchbay.Repo

  @contract String.duplicate("e", 64)
  @arguments String.duplicate("f", 64)
  @amount 5_000_000
  @release_tx "0x" <> String.duplicate("2", 64)
  @funded_at 1_800_000_000
  # What the synthetic Base node answers besides posts, sends and receipts.
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
    }
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

    old_escrow = Application.get_env(:patchbay, :escrow)

    node =
      start_supervised!(
        {Agent, fn -> %{post: :none, receipts: %{}, send: {:ok, @release_tx}, sent: 0} end}
      )

    # Synthetic operator key, generated for this run. It never reaches a real chain.
    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("c", 40),
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: base_node(node)
    )

    on_exit(fn -> Application.put_env(:patchbay, :escrow, old_escrow) end)
    %{tool: tool, node: node}
  end

  describe "each step starts only where it may" do
    # Every escrow step, what it writes, and the stored states it may start
    # from. Each is handed a copy of the report whose state the step accepts,
    # while the stored row says otherwise: only the stored state decides.
    @steps [
      {:record_escrow_credit, %{escrow_credit_tx_hash: "0x01"}, [nil]},
      {:fail_escrow_credit, %{}, [nil, :credit_submitted]},
      {:retry_escrow_credit, %{}, [:credit_failed]},
      {:confirm_escrow_credit, %{escrow_funded_at: ~U[2027-01-01 00:00:00Z]},
       [:credit_submitted, :credit_failed]},
      {:record_escrow_release, %{escrow_release_tx_hash: "0x02"}, [:credited]},
      {:fail_escrow_release, %{}, [:credited, :release_submitted]},
      {:retry_escrow_release, %{}, [:release_failed]},
      {:confirm_escrow_release, %{}, [:release_submitted, :release_failed]},
      {:record_escrow_refund, %{escrow_refund_tx_hash: "0x03"},
       [:credit_submitted, :credited, :credit_failed, :release_submitted, :release_failed]}
    ]

    for {action, input, from} <- @steps do
      test "#{action} moves a bounty only from #{inspect(from)}", %{tool: tool} do
        report = paid_report(tool, profile("aaa"))
        held_copy = %{report | escrow_status: hd(unquote(from))}

        for stored <- [nil | EscrowStatus.values()] do
          store(report, stored)

          result = step(held_copy, unquote(action), unquote(Macro.escape(input)))

          if stored in unquote(from) do
            assert {:ok, _moved} = result, "refused from #{inspect(stored)}"
          else
            assert {:error, %Ash.Error.Invalid{} = refused} = result,
                   "moved from #{inspect(stored)}"

            assert Exception.message(refused) =~ "has moved on"
            assert Forum.get_report!(report.id).escrow_status == stored
          end
        end
      end
    end
  end

  describe "accepting an answer" do
    test "takes a bounty Base was handed or holds, and nothing else", %{tool: tool} do
      asker = profile("aaa")
      refusals = %{nil => "not recorded on Base yet", credit_failed: "not recorded on Base yet"}

      for {status, words} <- refusals do
        report = paid_report(tool, asker)
        store(report, status)
        reply = reply(report, profile("bbb"))

        assert {:error, %Ash.Error.Invalid{} = refused} =
                 Forum.accept_reply(Forum.get_report!(report.id), reply.id, actor: asker)

        assert Exception.message(refused) =~ words
      end

      # Handed to Base and not confirmed yet: the asker may choose already,
      # and the payout waits until Base says it holds the money.
      sent = paid_report(tool, asker)
      store(sent, :credit_submitted)
      reply = reply(sent, profile("bbb"))
      {:ok, accepted} = Forum.accept_reply(Forum.get_report!(sent.id), reply.id, actor: asker)
      assert accepted.escrow_status == :credit_submitted
      assert {:cancel, _not_yet} = perform_job(SendEscrowRelease, job(sent))
    end

    test "refuses a thread with no bounty", %{tool: tool} do
      thread = free_report(tool)
      reply = reply(thread, profile("bbb"))

      assert {:error, %Ash.Error.Invalid{} = refused} =
               Forum.accept_reply(thread, reply.id, authorize?: false)

      assert Exception.message(refused) =~ "has no bounty"
    end

    test "refuses an answer moderation keeps off the board", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      reply = reply(report, profile("bbb"))

      {:ok, _held} =
        Ash.update(reply, %{visibility: :quarantined}, action: :set_visibility, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = refused} =
               Forum.accept_reply(report, reply.id, actor: asker)

      assert Exception.message(refused) =~ "not shown on the board"
      assert Forum.get_report!(report.id).accepted_reply_id == nil
    end

    test "the accepted answer stays the thread's answer", %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      winner = reply(report, profile("bbb"))
      other = reply(report, profile("ccc"))
      {:ok, accepted} = Forum.accept_reply(report, winner.id, actor: asker)

      # Once the money is paid out the thread has no money waiting, and the
      # ordinary mark still cannot name a different answer.
      paid = released(accepted)

      assert {:error, %Ash.Error.Invalid{} = refused} =
               Forum.mark_solution(paid, other.id, nil, asker)

      assert %SolutionRefused{reason: :already_awarded} = refusal(refused)
      assert Forum.get_report!(report.id).solution_reply_id == winner.id
    end
  end

  describe "paying out the accepted answer" do
    test "accepting queues the payout, and its job hands it to Base once", %{
      tool: tool,
      node: node
    } do
      asker = profile("aaa")
      report = credited(tool, asker)
      winner = profile("bbb")
      {:ok, accepted} = Forum.accept_reply(report, reply(report, winner).id, actor: asker)
      assert accepted.escrow_status == :credited
      assert_enqueued(worker: SendEscrowRelease, args: job(report))

      assert {:ok, _sent} = perform_job(SendEscrowRelease, job(report))

      sent = Forum.get_report!(report.id)
      assert sent.escrow_status == :release_submitted
      assert sent.escrow_release_tx_hash == @release_tx
      assert sent.escrow_release_sent_at
      assert Agent.get(node, & &1.sent) == 1

      # A second job finds the payout handed over and sends nothing.
      assert {:cancel, _moved_on} = perform_job(SendEscrowRelease, job(report))
      assert Agent.get(node, & &1.sent) == 1
    end

    test "a payout Base will not take is tried again, then left for a person, who sends it again",
         %{tool: tool, node: node} do
      asker = profile("aaa")
      report = credited(tool, asker)

      {:ok, _accepted} =
        Forum.accept_reply(report, reply(report, profile("bbb")).id, actor: asker)

      Agent.update(node, &%{&1 | send: :refused})

      assert catch_error(perform_job(SendEscrowRelease, job(report)))
      assert Forum.get_report!(report.id).escrow_status == :credited

      perform_job(SendEscrowRelease, job(report), attempt: 10, max_attempts: 10)
      failed = Forum.get_report!(report.id)
      assert failed.escrow_status == :release_failed
      assert failed.escrow_release_tx_hash == nil

      Agent.update(node, &%{&1 | send: {:ok, @release_tx}})
      {:ok, again} = Forum.retry_escrow_release(failed, authorize?: false)
      assert again.escrow_status == :credited
      assert_enqueued(worker: SendEscrowRelease, args: job(report))

      assert {:ok, _sent} = perform_job(SendEscrowRelease, job(report))
      assert Forum.get_report!(report.id).escrow_status == :release_submitted
    end
  end

  describe "watching Base for a payout" do
    setup %{tool: tool} do
      asker = profile("aaa")
      report = credited(tool, asker)
      {:ok, accepted} = Forum.accept_reply(report, reply(report, profile("bbb")).id, actor: asker)

      {:ok, sent} =
        Forum.record_escrow_release(accepted, %{escrow_release_tx_hash: @release_tx},
          authorize?: false
        )

      %{report: sent}
    end

    test "a payout the contract made is written as paid", %{report: report, node: node} do
      holds(node, 1)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :release_submitted

      holds(node, 2)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :released
    end

    test "a payout the contract refused in its block is written as failed", %{
      report: report,
      node: node
    } do
      holds(node, 1)
      Agent.update(node, &put_in(&1, [:receipts, @release_tx], "0x0"))
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :release_failed
    end

    test "a payout still not in a block an hour after it was sent is written as failed", %{
      report: report,
      node: node
    } do
      holds(node, 1)
      sent_ago(report, 59 * 60)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :release_submitted

      sent_ago(report, 61 * 60)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :release_failed
    end

    test "a payout written as failed that went through after all is written as paid", %{
      report: report,
      node: node
    } do
      {:ok, _failed} = Forum.fail_escrow_release(report, authorize?: false)

      holds(node, 1)
      assert %{failure: 0} = held_sweep()
      assert Forum.get_report!(report.id).escrow_status == :release_failed

      holds(node, 2)
      assert %{failure: 0} = held_sweep()
      assert Forum.get_report!(report.id).escrow_status == :released
    end

    test "money sent back on Base is written as refunded, whatever was sent", %{
      report: report,
      node: node
    } do
      holds(node, 3)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :refunded
    end
  end

  describe "watching Base for a credit" do
    test "a credit still not in a block an hour after it was sent is written as failed", %{
      tool: tool
    } do
      {:ok, report} =
        Forum.record_escrow_credit(
          paid_report(tool, profile("aaa")),
          %{escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)},
          authorize?: false
        )

      credit_sent_ago(report, 59 * 60)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :credit_submitted

      credit_sent_ago(report, 61 * 60)
      assert %{failure: 0} = sent_sweep()
      assert Forum.get_report!(report.id).escrow_status == :credit_failed
    end
  end

  describe "the database" do
    test "keeps only the known states", %{tool: tool} do
      report = paid_report(tool, profile("aaa"))
      assert {:error, "forum_reports_escrow_status_known"} = raw_store(report, "refund_failed")
    end

    test "keeps a state only on a report with a bounty", %{tool: tool} do
      assert {:error, "forum_reports_escrow_status_needs_bounty"} =
               raw_store(free_report(tool), "credited")
    end
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  defp paid_report(tool, asker) do
    Forum.file_priority_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: "The cart never changed.",
        priority_amount_atomic: @amount,
        payment_intent_id: Ash.UUID.generate()
      },
      actor: asker
    )
  end

  # Seeded by Patchbay itself: an ordinary thread, with no money on it.
  defp free_report(tool) do
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

  # Recording what the escrow said is the settlement path's own write, which
  # no actor may reach, so the setup writes it the way that path does.
  defp credited(tool, asker) do
    {:ok, submitted} =
      Forum.record_escrow_credit(
        paid_report(tool, asker),
        %{escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)},
        authorize?: false
      )

    {:ok, report} =
      Forum.confirm_escrow_credit(submitted, %{escrow_funded_at: DateTime.utc_now()},
        authorize?: false
      )

    report
  end

  # The payout's job and the watch of Base write these, with no actor.
  defp released(report) do
    {:ok, sent} =
      Forum.record_escrow_release(report, %{escrow_release_tx_hash: @release_tx},
        authorize?: false
      )

    {:ok, paid} = Forum.confirm_escrow_release(sent, authorize?: false)
    paid
  end

  defp reply(report, author) do
    {:ok, reply} =
      Forum.add_reply(
        %{
          report_id: report.id,
          browser_session_id: Ash.UUID.generate(),
          verdict: :verified_failure,
          note: "Same here."
        },
        actor: author
      )

    # Moderation's word is nobody's to give over HTTP either.
    {:ok, eligible} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)
    eligible
  end

  # Each money step is Patchbay's own write, which no actor may reach.
  defp step(report, action, input),
    do: Ash.update(report, input, action: action, authorize?: false)

  defp refusal(%Ash.Error.Invalid{errors: errors}),
    do: Enum.find(errors, &match?(%SolutionRefused{}, &1))

  defp job(report), do: %{"primary_key" => %{"id" => report.id}}
  defp sent_sweep, do: schedule_and_run_triggers({Forum.Report, :read_escrow_sent})
  defp held_sweep, do: schedule_and_run_triggers({Forum.Report, :read_escrow_held})

  # What the contract holds for every post: the same payer and amount, at a
  # status of 1 funded, 2 paid out or 3 sent back.
  defp holds(node, status) do
    payer = "0x" <> String.duplicate("a", 40)
    Agent.update(node, &%{&1 | post: {payer, @amount, status, @funded_at}})
  end

  # The row as it stands, written past every action, as another writer
  # would have left it.
  defp store(report, status) do
    Repo.query!("UPDATE forum_reports SET escrow_status = $1 WHERE id = $2", [
      status && Atom.to_string(status),
      Ecto.UUID.dump!(report.id)
    ])
  end

  # Inside its own savepoint, so the refused statement leaves the test's
  # transaction usable.
  defp raw_store(report, status) do
    Repo.transaction(fn ->
      case Repo.query("UPDATE forum_reports SET escrow_status = $1 WHERE id = $2", [
             status,
             Ecto.UUID.dump!(report.id)
           ]) do
        {:ok, written} ->
          written

        {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} ->
          Repo.rollback(constraint)
      end
    end)
  end

  defp sent_ago(report, seconds) do
    Repo.query!("UPDATE forum_reports SET escrow_release_sent_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -seconds),
      Ecto.UUID.dump!(report.id)
    ])
  end

  defp credit_sent_ago(report, seconds) do
    Repo.query!("UPDATE forum_reports SET escrow_credit_sent_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -seconds),
      Ecto.UUID.dump!(report.id)
    ])
  end

  defp base_node(node) do
    server =
      start_supervised!(
        {Bandit,
         plug: fn conn, _options ->
           {:ok, raw, conn} = Plug.Conn.read_body(conn)

           conn
           |> Plug.Conn.put_resp_content_type("application/json")
           |> Plug.Conn.send_resp(200, raw |> Jason.decode!() |> rpc(node) |> Jason.encode!())
         end,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp rpc(requests, node) when is_list(requests), do: Enum.map(requests, &rpc(&1, node))

  defp rpc(%{"id" => id, "method" => "eth_sendRawTransaction"}, node) do
    case Agent.get_and_update(node, &{&1.send, %{&1 | sent: &1.sent + 1}}) do
      {:ok, tx_hash} ->
        %{jsonrpc: "2.0", id: id, result: tx_hash}

      :refused ->
        %{jsonrpc: "2.0", id: id, error: %{code: -32_000, message: "execution reverted"}}
    end
  end

  defp rpc(%{"id" => id, "method" => "eth_getTransactionReceipt", "params" => [tx_hash]}, node) do
    receipt =
      case Agent.get(node, & &1.receipts[tx_hash]) do
        nil -> nil
        status -> %{"transactionHash" => tx_hash, "status" => status}
      end

    %{jsonrpc: "2.0", id: id, result: receipt}
  end

  defp rpc(%{"id" => id, "method" => "eth_call"}, node) do
    post = Agent.get(node, & &1.post)
    %{jsonrpc: "2.0", id: id, result: "0x" <> Base.encode16(encoded(post), case: :lower)}
  end

  defp rpc(%{"id" => id, "method" => method}, _node),
    do: %{jsonrpc: "2.0", id: id, result: Map.fetch!(@base_node, method)}

  # The escrow contract's `posts` answer: payer, amount, status, fundedAt.
  defp encoded(:none), do: encoded({"0x" <> String.duplicate("0", 40), 0, 0, 0})

  defp encoded({payer, amount, status, funded_at}) do
    ABI.TypeEncoder.encode(
      [Base.decode16!(String.slice(payer, 2..-1//1), case: :mixed), amount, status, funded_at],
      [:address, {:uint, 96}, {:uint, 8}, {:uint, 64}]
    )
  end
end
