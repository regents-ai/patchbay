defmodule PatchbayWeb.PaymentsAPI.WalletJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Patchbay.Escrow.Watch
  alias Patchbay.{Identity, Repo}

  @funded_at 1_790_000_000

  # What the synthetic Base node answers: every payment has landed, and every
  # transaction is taken.
  @fixed_rpc %{
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
    "eth_getTransactionReceipt" => %{blockNumber: "0x1", status: "0x1"},
    "eth_sendRawTransaction" => "0x" <> String.duplicate("f", 64)
  }

  # Synthetic fixture key, generated for this run. It never reaches a real chain.
  setup do
    unless Repo.config()[:database] == "patchbay_test" <> System.fetch_env!("MIX_TEST_PARTITION"),
      do: raise("Wallet journey requires its prepared disposable database")

    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    address = Siwa.EvmPersonalSign.public_key_to_address(public)
    secret = :crypto.strong_rand_bytes(32)
    owner = self()
    origin = "https://wallet-#{Ecto.UUID.generate()}.invalid"
    old_wallet = Application.get_env(:patchbay, :wallet_author)
    old_escrow = Application.get_env(:patchbay, :escrow)
    old_facilitator = Application.fetch_env!(:patchbay, Patchbay.Payments.Facilitator)
    # What the fake escrow contract answers about the report's post; the test
    # moves it from nothing, through a wrong amount, to the funded record.
    {:ok, chain} = Agent.start_link(fn -> :none end)

    broker =
      server(:wallet_broker, fn conn, _ ->
        {:ok, raw, conn} = read_body(conn)
        payload = Jason.decode!(raw)
        refute Map.has_key?(payload["headers"], "cookie")

        case Siwa.verify_authenticated_request(payload,
               secret: secret,
               audience: "patchbay",
               wallet_audiences: ["patchbay"]
             ) do
          {:ok, %{claims: claims}} ->
            answer(conn, 200, %{
              code: "http_envelope_valid",
              data: %{
                verified: true,
                walletAddress: claims["sub"],
                chainId: 8453,
                principal: %{
                  kind: "wallet",
                  wallet_address: claims["sub"],
                  chain_id: 8453,
                  audience: "patchbay"
                }
              }
            })

          {:error, reason} ->
            send(owner, {:broker_refused, reason})
            answer(conn, 401, %{error: %{code: "invalid_proof"}})
        end
      end)

    payment =
      server(:wallet_payment, fn conn, _ ->
        {:ok, raw, conn} = read_body(conn)
        request = Jason.decode!(raw)

        case conn.request_path do
          "/verify" ->
            answer(conn, 200, %{isValid: true})

          "/settle" ->
            send(owner, :settled)

            answer(conn, 200, %{
              success: true,
              transaction: "0x" <> String.duplicate("1", 64),
              network: "eip155:8453"
            })

          "/rpc" ->
            answer(conn, 200, rpc(request, Agent.get(chain, & &1)))
        end
      end)

    configured_broker = System.get_env("PATCHBAY_TEST_SIWA_URL") || broker
    if URI.parse(configured_broker).host != "127.0.0.1", do: raise("Test broker must be loopback")
    Application.put_env(:patchbay, :wallet_author, broker_url: configured_broker)

    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("c", 40),
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: payment <> "/rpc"
    )

    replace_facilitator(Keyword.merge(old_facilitator, url: payment, auth: nil))

    app =
      server(:wallet_product, fn conn, _ ->
        unboxed(fn -> PatchbayWeb.Endpoint.call(conn, PatchbayWeb.Endpoint.init([])) end)
      end)

    receipt = issue_receipt(configured_broker, secret, key, address)
    other_key = :crypto.strong_rand_bytes(32)
    {:ok, other_public} = ExSecp256k1.create_public_key(other_key)
    other_address = Siwa.EvmPersonalSign.public_key_to_address(other_public)
    other_receipt = issue_receipt(configured_broker, secret, other_key, other_address)

    on_exit(fn ->
      Application.put_env(:patchbay, :wallet_author, old_wallet)
      Application.put_env(:patchbay, :escrow, old_escrow)
      replace_facilitator(old_facilitator)

      unboxed(fn ->
        # Only records from this unique fixture origin and wallet are removed.
        Repo.query!(
          "DELETE FROM payment_receipts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE actor_profile_id IN (SELECT id FROM agent_profiles WHERE wallet_address=ANY($1)))",
          [[address, other_address]]
        )

        Repo.query!(
          "DELETE FROM forum_reports WHERE author_profile_id IN (SELECT id FROM agent_profiles WHERE wallet_address=ANY($1))",
          [[address, other_address]]
        )

        Repo.query!(
          "DELETE FROM payment_intents WHERE actor_profile_id IN (SELECT id FROM agent_profiles WHERE wallet_address=ANY($1))",
          [[address, other_address]]
        )

        Repo.query!("DELETE FROM agent_profiles WHERE wallet_address=ANY($1)", [
          [address, other_address]
        ])

        Repo.query!(
          "DELETE FROM forum_tools WHERE site_id IN (SELECT id FROM forum_sites WHERE origin=$1)",
          [URI.parse(origin).host]
        )

        Repo.query!("DELETE FROM forum_sites WHERE origin=$1", [URI.parse(origin).host])
      end)
    end)

    %{
      app: app,
      receipt: receipt,
      key: key,
      address: address,
      origin: origin,
      chain: chain,
      other: %{app: app, receipt: other_receipt, key: other_key, address: other_address}
    }
  end

  test "CLI external signatures reach Ash, settle once, publish and recover an autonomous report",
       c do
    assert is_binary(c.receipt)

    prepared =
      dispatch(c, ["payments", "prepare"], %{
        args: %{
          amount_usdc: "1.00",
          origin: c.origin,
          tool_name: "fixture",
          verdict: "unknown",
          note: "Untrusted fixture evidence"
        }
      })

    assert prepared["status"] == 201, inspect(prepared)
    id = prepared["body"]["id"]
    assert prepared["body"]["execute_url"] =~ "/api/agent/payment_intents/#{id}/execute"
    challenge = dispatch(c, ["payments", "execute", id], %{})
    assert challenge["status"] == 402
    assert is_binary(challenge["payment_required"])
    terms = challenge["body"]["payment_terms"]
    requirement = hd(terms["accepts"])

    payment = %{
      x402Version: 2,
      accepted: requirement,
      extensions: terms["extensions"],
      payload: %{
        signature: sign(c.key, "synthetic payment checked only by loopback facilitator"),
        authorization: %{
          from: c.address,
          to: requirement["payTo"],
          value: requirement["amount"],
          validAfter: "0",
          validBefore: Integer.to_string(System.system_time(:second) + 60),
          nonce: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        }
      }
    }

    paid =
      dispatch(c, ["payments", "execute", id], %{
        payment_signature: payment |> Jason.encode!() |> Base.encode64()
      })

    assert paid["status"] == 200
    assert paid["body"]["status"] == "applied"
    assert_receive :settled
    recovered = dispatch(c, ["payments", "get", id], %{})
    assert recovered["status"] == 200
    assert recovered["body"]["receipt"] == paid["body"]["receipt"]
    again = dispatch(c, ["payments", "execute", id], %{})
    assert again["body"]["receipt"] == paid["body"]["receipt"]
    refute_receive :settled, 100
    report = unboxed(fn -> Patchbay.Forum.get_report!(prepared["body"]["report_id"]) end)
    assert report.browser_session_id == nil
    profile = unboxed(fn -> Identity.get_profile!(report.author_profile_id) end)
    assert profile.authentication_origin == :wallet
    assert profile.human_name == nil
    assert profile.privy_user_id == nil
    # Payment received and bounty confirmed are two facts: the credit was
    # handed to Base, and nothing is confirmed until the contract says so.
    assert report.escrow_status == :credit_submitted
    assert report.escrow_funded_at == nil
    assert paid["body"]["credit_confirmation"] == "pending"
    assert paid["body"]["status_url"] =~ "/api/agent/payment_intents/#{id}"
    assert paid["body"]["next_action"] =~ "Do not pay again"

    # The contract has no post yet: still waiting, nothing sent again.
    assert unboxed(fn -> Watch.confirm() end) == {:ok, 0}

    assert unboxed(fn -> Patchbay.Forum.get_report!(report.id) end).escrow_status ==
             :credit_submitted

    # A post funded for another amount is not this bounty's confirmation.
    Agent.update(c.chain, fn _ -> {c.address, 2_000_000, 1, @funded_at} end)
    assert unboxed(fn -> Watch.confirm() end) == {:ok, 0}

    assert unboxed(fn -> Patchbay.Forum.get_report!(report.id) end).escrow_status ==
             :credit_submitted

    # The contract's record for this post, from this payer, for this amount.
    Agent.update(c.chain, fn _ -> {c.address, 1_000_000, 1, @funded_at} end)
    assert unboxed(fn -> Watch.confirm() end) == {:ok, 1}
    confirmed = unboxed(fn -> Patchbay.Forum.get_report!(report.id) end)
    assert confirmed.escrow_status == :credited
    assert DateTime.to_unix(confirmed.escrow_funded_at) == @funded_at

    assert dispatch(c, ["payments", "get", id], %{})["body"]["result"]["credit_confirmation"] ==
             "confirmed"

    refute_receive :settled, 100

    assert dispatch(c.other, ["payments", "get", id], %{})["status"] == 404
    assert dispatch(c.other, ["payments", "execute", id], %{})["status"] == 404
    assert dispatch(c, ["payments", "get", id], %{})["body"]["receipt"] == paid["body"]["receipt"]
    refute_receive :settled, 100

    # A different actual signing key cannot use this receipt to read the intent.
    other = %{c | key: :crypto.strong_rand_bytes(32)}
    assert dispatch(other, ["payments", "get", id], %{})["status"] == 401
  end

  test "changed body and replay are refused by cryptographic verification", c do
    command = ["payments", "prepare"]

    input =
      Map.merge(%{receipt: c.receipt, wallet_address: c.address}, %{
        args: %{amount_usdc: "1.00", origin: c.origin, tool_name: "fixture", verdict: "unknown"}
      })

    request = cli(command ++ ["--base-url", c.app, "--phase", "prepare"], input)["request"]
    signature = sign(c.key, request["message"])
    signed = %{request: request, signature: signature}
    first = cli(command ++ ["--base-url", c.app], signed)
    assert first["status"] == 201, inspect(first)
    assert cli(command ++ ["--base-url", c.app], signed)["status"] == 401
    # A direct client bypassing CLI validation still cannot alter covered JSON.
    bytes =
      signature |> String.trim_leading("0x") |> Base.decode16!(case: :mixed) |> Base.encode64()

    headers =
      Map.put(request["headers"], "signature", "sig1=:#{bytes}:")
      |> Map.put("content-type", "application/json")

    assert {:ok, %{status: 401}} =
             Req.post(c.app <> request["path"], headers: headers, body: "{}", retry: false)

    # Even a valid signature over a bodyless envelope cannot authorize parsed JSON.
    input = String.replace(request["headers"]["signature-input"], ~s( "content-digest"), "")

    message =
      request["message"]
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, ~s("content-digest")))
      |> Enum.join("\n")
      |> String.replace(~s( "content-digest"), "")

    no_digest_sig =
      sign(c.key, message)
      |> String.trim_leading("0x")
      |> Base.decode16!(case: :mixed)
      |> Base.encode64()

    no_digest =
      headers
      |> Map.delete("content-digest")
      |> Map.put("signature-input", input)
      |> Map.put("signature", "sig1=:#{no_digest_sig}:")

    assert {:ok, %{status: 401}} =
             Req.post(c.app <> request["path"],
               headers: no_digest,
               body: request["body"],
               retry: false
             )
  end

  test "chunked JSON captures exact bytes and cookies confer no authority", c do
    request =
      cli(["payments", "prepare", "--base-url", c.app, "--phase", "prepare"], %{
        receipt: c.receipt,
        wallet_address: c.address,
        args: %{amount_usdc: "1.00", origin: c.origin, tool_name: "fixture", verdict: "unknown"}
      })["request"]

    signature =
      sign(c.key, request["message"])
      |> String.trim_leading("0x")
      |> Base.decode16!(case: :mixed)
      |> Base.encode64()

    headers =
      request["headers"]
      |> Map.put("signature", "sig1=:#{signature}:")
      |> Map.put("content-type", "application/json")
      |> Map.put("cookie", "unrelated_browser_cookie=ignored")

    <<first::binary-size(10), rest::binary>> = request["body"]

    assert {:ok, %{status: 201}} =
             Req.post(c.app <> request["path"],
               headers: headers,
               body: Stream.map([first, rest], & &1),
               retry: false
             )

    assert {:ok, %{status: 413}} =
             Req.post(c.app <> request["path"],
               headers: headers,
               body: Jason.encode!(%{note: String.duplicate("a", 100_001)}),
               retry: false
             )
  end

  defp issue_receipt(configured_broker, secret, key, address) do
    if System.get_env("PATCHBAY_TEST_SIWA_URL") do
      nonce =
        cli(
          ["wallet", "nonce", "--siwa-url", configured_broker, "--wallet-address", address],
          nil
        )["body"]["data"]

      assert is_map(nonce)

      proof = %{
        wallet_address: address,
        chain_id: 8453,
        audience: "patchbay",
        nonce: nonce["nonce"],
        message: nonce["message"],
        signature: sign(key, nonce["message"])
      }

      verified = cli(["wallet", "verify", "--siwa-url", configured_broker], proof)
      assert verified["ok"]
      verified["body"]["data"]["receipt"]
    else
      {:ok, %{token: token}} =
        Siwa.Receipt.create(
          %{
            "typ" => "siwa_wallet_receipt",
            "sub" => address,
            "chain_id" => 8453,
            "aud" => "patchbay",
            "key_id" => address,
            "verified" => "wallet_signature",
            "nonce" => Ecto.UUID.generate(),
            "jti" => Ecto.UUID.generate()
          },
          secret: secret
        )

      token
    end
  end

  defp dispatch(c, command, args) do
    input = Map.merge(%{receipt: c.receipt, wallet_address: c.address}, args)
    request = cli(command ++ ["--base-url", c.app, "--phase", "prepare"], input)["request"]
    assert is_map(request)

    cli(command ++ ["--base-url", c.app], %{
      request: request,
      signature: sign(c.key, request["message"])
    })
  end

  defp cli(args, input) do
    script = Path.expand("../../../../../cli/test/pipe-invoke.js", __DIR__)

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        args: [script]
      ])

    Port.command(port, Jason.encode!(%{args: args, input: input}) <> "\n")
    receive_output(port, "") |> Jason.decode!()
  end

  defp receive_output(port, output) do
    receive do
      {^port, {:data, data}} -> receive_output(port, output <> data)
      {^port, {:exit_status, 0}} -> output
      {^port, {:exit_status, _}} -> flunk("CLI harness failed")
    after
      20_000 ->
        Port.close(port)
        flunk("CLI harness timed out")
    end
  end

  defp sign(key, message) do
    {:ok, signature} =
      Siwa.EvmPersonalSign.sign_personal_signature(Base.encode16(key, case: :lower), message)

    signature
  end

  defp server(id, plug) do
    server =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: id)
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp answer(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
  defp rpc(requests, post) when is_list(requests), do: Enum.map(requests, &rpc(&1, post))

  defp rpc(%{"id" => id, "method" => method}, post),
    do: %{jsonrpc: "2.0", id: id, result: rpc_value(method, post)}

  defp rpc_value("eth_call", post), do: "0x" <> Base.encode16(encoded_post(post), case: :lower)
  defp rpc_value(method, _post), do: Map.fetch!(@fixed_rpc, method)

  # The escrow contract's `posts` answer: payer, amount, status, fundedAt.
  defp encoded_post(:none), do: encoded_post({"0x" <> String.duplicate("0", 40), 0, 0, 0})

  defp encoded_post({payer, amount, status, funded_at}) do
    ABI.TypeEncoder.encode(
      [Base.decode16!(String.slice(payer, 2..-1//1), case: :mixed), amount, status, funded_at],
      [:address, {:uint, 96}, {:uint, 8}, {:uint, 64}]
    )
  end

  defp replace_facilitator(opts) do
    name = Patchbay.Payments.Facilitator
    Supervisor.terminate_child(Patchbay.Supervisor, name)
    Supervisor.delete_child(Patchbay.Supervisor, name)
    Application.put_env(:patchbay, name, opts)

    {:ok, _} =
      Supervisor.start_child(
        Patchbay.Supervisor,
        {X402.Facilitator, Keyword.put(opts, :name, name)}
      )
  end
end
