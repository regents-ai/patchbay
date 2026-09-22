defmodule PatchbayWeb.PaymentsAPI.PaymentRecoveryTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.SpecialPost
  alias Patchbay.Repo
  alias PatchbayWeb.Plugs.CurrentProfile

  @endpoint PatchbayWeb.Endpoint
  @facilitator Patchbay.Payments.Facilitator

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
    unless Repo.config()[:database] == "patchbay_test" <> System.get_env("MIX_TEST_PARTITION", "") do
      raise "Recovery tests require the disposable test database"
    end

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
    original = Application.fetch_env!(:patchbay, @facilitator)
    assert original[:max_retries] == 0

    configured =
      Keyword.merge(original,
        url: "http://127.0.0.1:#{port}",
        auth: nil,
        receive_timeout_ms: 2_000
      )

    replace_facilitator(configured)
    on_exit(fn -> replace_facilitator(original) end)

    {payer, recipient, intent} =
      unboxed(fn ->
        payer = profile("a")
        recipient = profile("b")

        {:ok, intent} =
          Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: recipient},
            actor: payer
          )

        {payer, recipient, intent}
      end)

    on_exit(fn ->
      unboxed(fn ->
        # Only this case's committed fixtures are removed; other tests and
        # worktrees own their own records and databases.
        payer_id = Ecto.UUID.dump!(payer.id)

        Repo.query!(
          "DELETE FROM payment_receipts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE actor_profile_id=$1)",
          [payer_id]
        )

        Repo.query!("DELETE FROM forum_reports WHERE author_profile_id=$1", [payer_id])
        Repo.query!("DELETE FROM payment_intents WHERE actor_profile_id=$1", [payer_id])

        Repo.query!("DELETE FROM agent_profiles WHERE id=ANY($1)", [
          [payer_id, Ecto.UUID.dump!(recipient.id)]
        ])
      end)
    end)

    %{payer: payer, recipient: recipient, intent: intent, rpc_url: "http://127.0.0.1:#{port}/rpc"}
  end

  test "pending commits before dispatch and a 503 never repeats settlement", c do
    {worker, ref} = execute(c)
    assert_receive {:settle, service, _payload}, 3_000
    assert recovery(c)["status"] == "settlement_pending"
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 409)["status"] == "settlement_pending"
    send(service, {:reply, 503, %{error: "uncertain"}})
    assert_receive {:done, ^worker, response}, 3_000
    assert json_response(response, 409)["status"] == "settlement_pending"
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    refute_receive {:settle, _, _}, 200
    assert recovery(c)["recovery_required"]
  end

  test "a killed caller leaves a durable attempt without charging again", c do
    {worker, ref} = execute(c)
    assert_receive {:settle, service, _payload}, 3_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    send(service, {:reply, 200, settled("1")})
    assert recovery(c)["status"] == "settlement_pending"
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 409)["status"] == "settlement_pending"
    refute_receive {:settle, _, _}, 200
  end

  test "distinct deliberate intents settle independently and GET returns the receipt", c do
    second =
      unboxed(fn ->
        Payments.prepare_agent_tip!(%{amount_atomic: 1_000_000, recipient: c.recipient},
          actor: c.payer
        )
      end)

    {first_worker, _} = execute(c)
    assert_receive {:settle, first_service, _}, 3_000
    {second_worker, _} = execute(%{c | intent: second})
    assert_receive {:settle, second_service, _}, 3_000
    send(second_service, {:reply, 200, settled("2")})
    assert_receive {:done, ^second_worker, response}, 3_000
    assert json_response(response, 200)["status"] == "applied"
    send(first_service, {:reply, 200, settled("3")})
    assert_receive {:done, ^first_worker, response}, 3_000
    assert json_response(response, 200)["status"] == "applied"
    assert recovery(c)["receipt"]["transaction_hash"] == settled("3")["transaction"]

    hidden =
      unboxed(fn -> signed_in(c.recipient) |> get("/api/payment_intents/#{c.intent.id}") end)

    assert json_response(hidden, 404)["problem_code"] == "not_found"
  end

  test "receipt persistence failure leaves the already committed pending marker", c do
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    # Inject a persistence failure only for this case's intent in the owned
    # disposable database. Other receipts still satisfy this constraint.
    name = "recovery_" <> String.replace(c.intent.id, "-", "")

    unboxed(fn ->
      Repo.query!(
        "ALTER TABLE payment_receipts ADD CONSTRAINT #{name} CHECK (payment_intent_id <> '#{c.intent.id}'::uuid)"
      )
    end)

    on_exit(fn ->
      unboxed(fn -> Repo.query!("ALTER TABLE payment_receipts DROP CONSTRAINT #{name}") end)
    end)

    send(service, {:reply, 200, settled("4")})

    receive do
      {:done, ^worker, _response} -> :ok
      {:DOWN, _ref, :process, ^worker, _reason} -> :ok
    after
      3_000 -> flunk("settlement caller did not finish")
    end

    assert recovery(c)["status"] == "settlement_pending"
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 409)["status"] == "settlement_pending"
    refute_receive {:settle, _, _}, 200
  end

  test "settled receipt survives a publication failure and is never charged again", c do
    c = priority(c)
    name = "recovery_" <> String.replace(c.intent.id, "-", "")

    unboxed(fn ->
      Repo.query!(
        "ALTER TABLE forum_reports ADD CONSTRAINT #{name} CHECK (id <> '#{c.intent.target_id}'::uuid)"
      )
    end)

    on_exit(fn ->
      unboxed(fn -> Repo.query!("ALTER TABLE forum_reports DROP CONSTRAINT #{name}") end)
    end)

    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("5")})
    await_finish(worker)
    recovered = recovery(c)
    assert recovered["status"] == "settled"
    assert recovered["receipt"]["transaction_hash"] == settled("5")["transaction"]
    assert recovered["recovery_required"]
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 202)["receipt"] == recovered["receipt"]

    assert unboxed(fn ->
             Repo.query!("SELECT id FROM forum_reports WHERE id=$1", [
               Ecto.UUID.dump!(c.intent.target_id)
             ]).rows
           end) == []

    refute_receive {:settle, _, _}, 200
  end

  test "an unavailable escrow leaves one report and a recoverable settled receipt", c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("6")})
    assert_receive {:done, ^worker, response}, 3_000
    body = json_response(response, 202)
    assert body["status"] == "settled"
    assert body["recovery_required"]
    assert body["receipt"]["transaction_hash"] == settled("6")["transaction"]
    report = unboxed(fn -> Patchbay.Forum.get_report!(c.intent.target_id) end)
    assert report.escrow_status == :credit_failed
    assert report.escrow_credit_tx_hash == nil
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 202)["receipt"] == body["receipt"]
    assert recovery(c)["receipt"] == body["receipt"]

    assert unboxed(fn -> Patchbay.Forum.get_report!(report.id) end) == report

    refute_receive {:settle, _, _}, 200
  end

  test "receipt recovery does not depend on the recipient's current profile", c do
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("7")})
    assert_receive {:done, ^worker, response}, 3_000
    receipt = json_response(response, 200)["receipt"]

    unboxed(fn ->
      Repo.query!("DELETE FROM agent_profiles WHERE id=$1", [Ecto.UUID.dump!(c.recipient.id)])
    end)

    recovered = recovery(c)
    assert recovered["receipt"] == receipt
    assert recovered["recipient"]["profile_available"] == false
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    assert json_response(duplicate, 200)["receipt"] == receipt
    refute_receive {:settle, _, _}, 200
  end

  test "an applied intent retains its receipt when its report is unavailable", c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("8")})
    assert_receive {:done, ^worker, response}, 3_000
    receipt = json_response(response, 202)["receipt"]

    unboxed(fn ->
      # Represent a historical applied intent whose optional report is now absent.
      intent = Payments.get_payment_intent!(c.intent.id, actor: c.payer)
      Payments.mark_applied!(intent, actor: c.payer)
      Repo.query!("DELETE FROM forum_reports WHERE id=$1", [Ecto.UUID.dump!(c.intent.target_id)])
    end)

    recovered = recovery(c)
    assert recovered["receipt"] == receipt
    assert recovered["result"]["result_available"] == false
    assert recovered["recovery_required"]
    duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
    body = json_response(duplicate, 200)
    assert body["receipt"] == receipt
    assert body["result_available"] == false
    refute_receive {:settle, _, _}, 200
  end

  for failure <- [:caller_crash, :applied_write_failure] do
    @failure failure
    test "receipt and report commit before escrow dispatch: #{@failure}", c do
      c = priority(c)

      Application.put_env(:patchbay, :escrow,
        contract_address: "0x" <> String.duplicate("c", 40),
        operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        rpc_url: c.rpc_url
      )

      {worker, ref} = execute(c)
      assert_receive {:settle, service, _}, 3_000
      send(service, {:reply, 200, settled("9")})
      assert_receive {:landed?, landing}, 3_000
      send(landing, {:rpc_reply, landed("9")})
      assert_receive {:credit, rpc}, 3_000
      # The only RPC is the loopback stub; its synthetic chain has no funds.
      assert recovery(c)["receipt"]["transaction_hash"] == settled("9")["transaction"]
      report = unboxed(fn -> Patchbay.Forum.get_report!(c.intent.target_id) end)
      assert report.id == c.intent.target_id
      hash = "0x" <> String.duplicate("f", 64)

      if @failure == :caller_crash do
        Process.exit(worker, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
        send(rpc, {:rpc_reply, hash})
      else
        name = "recovery_" <> String.replace(c.intent.id, "-", "")

        unboxed(fn ->
          Repo.query!(
            "ALTER TABLE payment_intents ADD CONSTRAINT #{name} CHECK (id <> '#{c.intent.id}'::uuid OR status <> 'applied')"
          )
        end)

        on_exit(fn ->
          unboxed(fn -> Repo.query!("ALTER TABLE payment_intents DROP CONSTRAINT #{name}") end)
        end)

        send(rpc, {:rpc_reply, hash})
        await_finish(worker)
        credited = unboxed(fn -> Patchbay.Forum.get_report!(report.id) end)
        assert credited.escrow_status == :credit_submitted
        assert credited.escrow_funded_at == nil
        assert credited.escrow_credit_tx_hash == hash
      end

      recovered = recovery(c)
      assert recovered["status"] == "settled"
      assert recovered["recovery_required"]
      assert recovered["result"]["credit_confirmation"] in ["pending", "needs_attention"]
      duplicate = unboxed(fn -> signed_in(c.payer) |> post(path(c.intent), %{}) end)
      assert json_response(duplicate, 202)["receipt"] == recovered["receipt"]
      refute_receive {:settle, _, _}, 200
      refute_receive {:credit, _}, 200
    end
  end

  test "the credit waits for the payment to land, and one Base would not take is sent again",
       c do
    c = priority(c)
    {worker, _} = execute(c)
    assert_receive {:settle, service, _}, 3_000
    send(service, {:reply, 200, settled("a")})
    assert_receive {:done, ^worker, response}, 3_000
    assert json_response(response, 202)["status"] == "settled"
    # No operator was set up when it was paid, so Base was never asked.
    report = unboxed(fn -> Patchbay.Forum.get_report!(c.intent.target_id) end)
    assert report.escrow_status == :credit_failed

    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("c", 40),
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: c.rpc_url
    )

    parent = self()

    spawn(fn ->
      send(parent, {:again, unboxed(fn -> SpecialPost.credit_again(report.id) end)})
    end)

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
             unboxed(fn -> SpecialPost.credit_again(report.id) end)

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

  defp priority(c) do
    original = Application.get_env(:patchbay, :escrow)
    # No key or RPC is configured: escrow submission cannot reach any chain.
    Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("c", 40))
    on_exit(fn -> Application.put_env(:patchbay, :escrow, original) end)

    draft = %{
      "origin" => "https://recovery-#{Ecto.UUID.generate()}.invalid",
      "tool_name" => "fixture",
      "verdict" => "unknown"
    }

    {tool, intent} =
      unboxed(fn ->
        {:ok, tool} = Patchbay.Forum.OtherSiteReport.resolve_tool(draft)

        {:ok, intent} =
          Payments.prepare_special_post(%{amount_atomic: 1_000_000, tool: tool, draft: draft},
            actor: c.payer
          )

        {tool, intent}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM forum_reports WHERE tool_id=$1", [Ecto.UUID.dump!(tool.id)])
        Repo.query!("DELETE FROM forum_tools WHERE id=$1", [Ecto.UUID.dump!(tool.id)])
        Repo.query!("DELETE FROM forum_sites WHERE id=$1", [Ecto.UUID.dump!(tool.site_id)])
      end)
    end)

    %{c | intent: intent}
  end

  defp await_finish(worker) do
    receive do
      {:done, ^worker, _response} -> :ok
      {:DOWN, _ref, :process, ^worker, _reason} -> :ok
    after
      3_000 -> flunk("settlement caller did not finish")
    end
  end

  defp execute(c) do
    parent = self()

    spawn_monitor(fn ->
      response =
        unboxed(fn ->
          challenge = signed_in(c.payer) |> post(path(c.intent), %{}) |> json_response(402)
          terms = challenge["payment_terms"]
          requirement = hd(terms["accepts"])

          payment = %{
            "x402Version" => 2,
            "accepted" => requirement,
            "extensions" => terms["extensions"],
            "payload" => %{
              "signature" => "0x" <> String.duplicate("1", 130),
              "authorization" => %{
                "from" => c.payer.wallet_address,
                "to" => requirement["payTo"],
                "value" => requirement["amount"],
                "validAfter" => "0",
                "validBefore" => Integer.to_string(System.system_time(:second) + 60),
                "nonce" => "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
              }
            }
          }

          signed_in(c.payer)
          |> put_req_header("payment-signature", payment |> Jason.encode!() |> Base.encode64())
          |> post(path(c.intent), %{})
        end)

      send(parent, {:done, self(), response})
    end)
  end

  defp recovery(c),
    do:
      unboxed(fn ->
        signed_in(c.payer) |> get("/api/payment_intents/#{c.intent.id}") |> json_response(200)
      end)

  defp path(intent), do: "/api/payment_intents/#{intent.id}/execute"
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp signed_in(profile),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), profile.id)

  defp profile(letter),
    do:
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:recovery-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate(letter, 40)
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

  defp replace_facilitator(options) do
    Supervisor.terminate_child(Patchbay.Supervisor, @facilitator)
    Supervisor.delete_child(Patchbay.Supervisor, @facilitator)
    Application.put_env(:patchbay, @facilitator, options)

    {:ok, _} =
      Supervisor.start_child(
        Patchbay.Supervisor,
        {X402.Facilitator, Keyword.put(options, :name, @facilitator)}
      )
  end
end
