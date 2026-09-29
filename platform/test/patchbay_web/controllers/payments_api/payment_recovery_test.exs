defmodule PatchbayWeb.PaymentsAPI.PaymentRecoveryTest do
  # What Patchbay does around a payment the payments library settled: the
  # report or tip it paid for, and the escrow credit handed to Base after it.
  # The settlement itself is the library's, and its own tests cover it.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias Patchbay.Payments.AgentTip
  alias Patchbay.Payments.SpecialPost
  alias Patchbay.Repo
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.WalletSigner
  alias RegentPayments.Purchase

  # What the synthetic Base node answers to every question but the two a
  # test answers itself.
  @fixed_rpc %{
    "eth_chainId" => "0x7a69",
    "eth_getTransactionCount" => "0x0",
    "eth_estimateGas" => "0x186a0",
    "eth_gasPrice" => "0x3b9aca00",
    "eth_maxPriorityFeePerGas" => "0x1",
    "eth_feeHistory" => %{
      "oldestBlock" => "0x0",
      "baseFeePerGas" => ["0x1", "0x1"],
      "gasUsedRatio" => [0.5],
      "reward" => [["0x1"]]
    }
  }

  setup do
    owner = self()

    server =
      start_supervised!(
        {Bandit,
         plug: fn conn, _opts ->
           {:ok, body, conn} = read_body(conn)

           {status, answer} =
             cond do
               conn.request_path == "/rpc" ->
                 {200, rpc_answer(Jason.decode!(body), owner)}

               conn.request_path == "/verify" ->
                 {200, %{"isValid" => true}}

               true ->
                 send(owner, {:settle, self(), Jason.decode!(body)})

                 receive do
                   {:reply, status, answer} -> {status, answer}
                 after
                   5_000 -> {503, %{error: "fixture timeout"}}
                 end
             end

           conn
           |> put_resp_content_type("application/json")
           |> send_resp(status, Jason.encode!(answer))
         end,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    Patchbay.PaymentService.stand_in("http://127.0.0.1:#{port}", receive_timeout_ms: 2_000)

    wallet = WalletSigner.new()
    payer = profile(wallet.address)
    recipient = profile("0x" <> String.duplicate("b", 40))

    {:ok, intent} =
      Purchase.prepare(AgentTip, %{amount_atomic: 1_000_000, recipient: recipient}, payer)

    %{
      payer: payer,
      wallet: wallet,
      recipient: recipient,
      intent: intent,
      rpc_url: "http://127.0.0.1:#{port}/rpc"
    }
  end

  test "settled receipt survives a publication failure and is never charged again", c do
    c = priority(c)
    name = "recovery_" <> String.replace(c.intent.id, "-", "")

    Repo.query!(
      "ALTER TABLE forum_reports ADD CONSTRAINT #{name} CHECK (id <> '#{c.intent.target_id}'::uuid)"
    )

    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("5")})
    await_finish(worker)
    recovered = recovery(c)
    assert recovered["status"] == "settled"
    assert recovered["receipt"]["transaction_hash"] == settled("5")["transaction"]
    assert recovered["recovery_required"]
    duplicate = signed_in(c.payer) |> post(path(c.intent), %{})
    assert json_response(duplicate, 202)["receipt"] == recovered["receipt"]
    assert {:error, _} = Forum.get_report(c.intent.target_id)
    refute_receive {:settle, _, _}, 200
  end

  test "an unavailable escrow leaves one report, its credit waiting for a person", c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("6")})
    assert_receive {:done, ^worker, response}, 3_000
    body = json_response(response, 200)
    assert body["status"] == "applied"
    assert body["credit_confirmation"] == "needs_attention"
    assert body["receipt"]["transaction_hash"] == settled("6")["transaction"]
    report = Forum.get_report!(c.intent.target_id)
    assert report.escrow_status == :credit_failed
    assert report.escrow_credit_tx_hash == nil
    duplicate = signed_in(c.payer) |> post(path(c.intent), %{})
    assert json_response(duplicate, 200)["receipt"] == body["receipt"]
    assert recovery(c)["receipt"] == body["receipt"]
    assert Forum.get_report!(report.id) == report
    refute_receive {:settle, _, _}, 200
  end

  test "receipt recovery does not depend on the recipient's current profile", c do
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("7")})
    assert_receive {:done, ^worker, response}, 3_000
    receipt = json_response(response, 200)["receipt"]

    Repo.query!("DELETE FROM agent_profiles WHERE id=$1", [Ecto.UUID.dump!(c.recipient.id)])

    recovered = recovery(c)
    assert recovered["receipt"] == receipt
    assert recovered["recipient"]["profile_available"] == false
    duplicate = signed_in(c.payer) |> post(path(c.intent), %{})
    assert json_response(duplicate, 200)["receipt"] == receipt
    refute_receive {:settle, _, _}, 200
  end

  test "an applied intent retains its receipt when its report is unavailable", c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("8")})
    assert_receive {:done, ^worker, response}, 3_000
    receipt = json_response(response, 200)["receipt"]

    Repo.query!("DELETE FROM forum_reports WHERE id=$1", [Ecto.UUID.dump!(c.intent.target_id)])

    recovered = recovery(c)
    assert recovered["receipt"] == receipt
    assert recovered["result"]["result_available"] == false
    assert recovered["recovery_required"]
    duplicate = signed_in(c.payer) |> post(path(c.intent), %{})
    body = json_response(duplicate, 200)
    assert body["receipt"] == receipt
    assert body["result_available"] == false
    refute_receive {:settle, _, _}, 200
  end

  test "a credit is handed to Base once, even when its caller dies on the way", c do
    c = priority(c)
    operator(c)

    {worker, ref} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("9")})
    assert_receive {:landed?, landing}, 3_000
    send(landing, {:rpc_reply, landed("9")})
    assert_receive {:credit, rpc}, 3_000

    # The report is published and its credit claimed before Base is asked.
    report = Forum.get_report!(c.intent.target_id)
    assert report.escrow_status == :credit_submitted
    assert report.escrow_credit_tx_hash == nil

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    send(rpc, {:rpc_reply, "0x" <> String.duplicate("f", 64)})

    recovered = recovery(c)
    assert recovered["status"] == "applied"
    assert recovered["receipt"]["transaction_hash"] == settled("9")["transaction"]
    assert recovered["result"]["credit_confirmation"] == "pending"
    duplicate = signed_in(c.payer) |> post(path(c.intent), %{})
    assert json_response(duplicate, 200)["receipt"] == recovered["receipt"]
    refute_receive {:settle, _, _}, 200
    refute_receive {:landed?, _}, 200
    refute_receive {:credit, _}, 200
  end

  test "the credit waits for the payment to land, and one Base would not take is sent again",
       c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("a")})
    assert_receive {:done, ^worker, response}, 3_000
    assert json_response(response, 200)["status"] == "applied"
    # No operator was set up when it was paid, so Base was never asked.
    report = Forum.get_report!(c.intent.target_id)
    assert report.escrow_status == :credit_failed

    operator(c)
    parent = self()
    spawn(fn -> send(parent, {:again, SpecialPost.credit_again(report.id)}) end)

    # Not in a block yet: the credit is not sent, and Base is asked again.
    assert_receive {:landed?, landing}, 3_000
    send(landing, {:rpc_reply, nil})
    refute_receive {:credit, _}, 200
    assert_receive {:landed?, landing}, 3_000
    send(landing, {:rpc_reply, landed("a")})

    assert_receive {:credit, rpc}, 3_000
    hash = "0x" <> String.duplicate("e", 64)
    send(rpc, {:rpc_reply, hash})
    assert_receive {:again, {:ok, credited}}, 3_000
    assert credited.escrow_status == :credit_submitted
    assert credited.escrow_credit_tx_hash == hash

    # Handed over once; a second ask leaves it as it is.
    assert {:error, {:not_credit_failed, :credit_submitted}} =
             SpecialPost.credit_again(report.id)

    refute_receive {:landed?, _}, 200
  end

  defp rpc_answer(requests, owner) when is_list(requests),
    do: Enum.map(requests, &rpc_answer(&1, owner))

  defp rpc_answer(%{"id" => id, "method" => method}, owner),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => rpc_value(method, owner)}

  # The two answers a test gives itself: whether the payment has landed, and
  # the hash of the credit sent.
  defp rpc_value("eth_getTransactionReceipt", owner), do: ask(owner, :landed?)
  defp rpc_value("eth_sendRawTransaction", owner), do: ask(owner, :credit)

  defp rpc_value(method, _owner),
    do:
      Map.get_lazy(@fixed_rpc, method, fn -> raise "unexpected synthetic RPC method #{method}" end)

  defp ask(owner, question) do
    send(owner, {question, self()})

    receive do
      {:rpc_reply, value} -> value
    after
      5_000 -> raise "#{question} fixture timeout"
    end
  end

  # A paid priority report's intent in place of the tip's. No key or RPC is
  # configured: escrow submission cannot reach any chain until `operator/1`.
  defp priority(c) do
    original = Application.get_env(:patchbay, :escrow)
    Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("c", 40))
    on_exit(fn -> Application.put_env(:patchbay, :escrow, original) end)

    draft = %{
      "origin" => "https://recovery-#{Ecto.UUID.generate()}.invalid",
      "tool_name" => "fixture",
      "verdict" => "unknown"
    }

    {:ok, tool} = Patchbay.Forum.OtherSiteReport.resolve_tool(draft)

    {:ok, intent} =
      Purchase.prepare(
        SpecialPost,
        %{amount_atomic: 1_000_000, tool: tool, draft: draft},
        c.payer
      )

    %{c | intent: intent}
  end

  # An operator that can send the credit, to the synthetic Base node.
  defp operator(c) do
    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("c", 40),
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: c.rpc_url
    )
  end

  defp await_finish(worker) do
    receive do
      {:done, ^worker, _response} -> :ok
      {:DOWN, _ref, :process, ^worker, _reason} -> :ok
    after
      3_000 -> flunk("settlement caller did not finish")
    end
  end

  # The page's two presses, from a caller of its own: the review, then the
  # signed payment.
  defp execute(c) do
    parent = self()

    spawn_monitor(fn ->
      %{"review" => review} =
        signed_in(c.payer)
        |> post(path(c.intent), %{active_wallet: c.wallet.address})
        |> json_response(402)

      response =
        signed_in(c.payer)
        |> post(path(c.intent), %{
          active_wallet: c.wallet.address,
          review_id: review["id"],
          signature: WalletSigner.sign(c.wallet, review)
        })

      send(parent, {:done, self(), response})
    end)
  end

  defp recovery(c),
    do: signed_in(c.payer) |> get("/api/payment_intents/#{c.intent.id}") |> json_response(200)

  defp path(intent), do: "/api/payment_intents/#{intent.id}/execute"

  defp signed_in(profile),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(profile.id)

  defp profile(address),
    do:
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:recovery-#{Ecto.UUID.generate()}",
        wallet_address: address
      })

  defp landed(letter),
    do: %{
      "transactionHash" => "0x" <> String.duplicate(letter, 64),
      "blockNumber" => "0x1",
      "status" => "0x1"
    }

  defp settled(letter),
    do: %{
      "success" => true,
      "transaction" => "0x" <> String.duplicate(letter, 64),
      "network" => "eip155:8453"
    }
end
