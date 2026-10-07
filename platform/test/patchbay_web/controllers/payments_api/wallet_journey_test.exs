defmodule PatchbayWeb.PaymentsAPI.WalletJourneyTest do
  # Everything runs in this test's own database transaction: the product
  # server below answers each request through it, and it is rolled back at
  # the end.
  use Patchbay.DataCase, async: false
  import Plug.Conn
  alias Patchbay.Escrow.Watch
  alias Patchbay.Identity

  @funded_at 1_790_000_000
  @intents "/api/agent/payment_intents"

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
    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    address = Siwa.EvmPersonalSign.public_key_to_address(public)
    secret = :crypto.strong_rand_bytes(32)
    owner = self()
    origin = "https://wallet-#{Ecto.UUID.generate()}.invalid"
    old_wallet = Application.get_env(:patchbay, :wallet_author)
    old_escrow = Application.get_env(:patchbay, :escrow)
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
                },
                agentRegistration: nil,
                agentBook: nil
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

    Application.put_env(:patchbay, :wallet_author, broker_url: broker)

    Application.put_env(:patchbay, :escrow,
      contract_address: "0x" <> String.duplicate("c", 40),
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: payment <> "/rpc"
    )

    Patchbay.PaymentService.stand_in(payment)

    app =
      server(:wallet_product, fn conn, _ ->
        PatchbayWeb.Endpoint.call(conn, PatchbayWeb.Endpoint.init([]))
      end)

    receipt = issue_receipt(secret, address)
    other_key = :crypto.strong_rand_bytes(32)
    {:ok, other_public} = ExSecp256k1.create_public_key(other_key)
    other_address = Siwa.EvmPersonalSign.public_key_to_address(other_public)
    other_receipt = issue_receipt(secret, other_address)

    on_exit(fn ->
      Application.put_env(:patchbay, :wallet_author, old_wallet)
      Application.put_env(:patchbay, :escrow, old_escrow)
    end)

    %{
      app: app,
      secret: secret,
      receipt: receipt,
      key: key,
      address: address,
      origin: origin,
      chain: chain,
      other: %{
        app: app,
        secret: secret,
        receipt: other_receipt,
        key: other_key,
        address: other_address
      }
    }
  end

  test "external signatures reach Ash, settle once, publish and recover an autonomous report",
       c do
    assert is_binary(c.receipt)

    prepared =
      prepare(c, %{
        amount_usdc: "1.00",
        origin: c.origin,
        tool_name: "fixture",
        verdict: "unknown",
        note: "Untrusted fixture evidence"
      })

    assert prepared["status"] == 201, inspect(prepared)
    id = prepared["body"]["id"]
    assert prepared["body"]["execute_url"] =~ "/api/agent/payment_intents/#{id}/execute"
    challenge = execute(c, id)
    assert challenge["status"] == 402
    assert is_binary(challenge["payment_required"])
    terms = challenge["body"]["payment_terms"]
    requirement = hd(terms["accepts"])

    payment = %{
      x402Version: 2,
      accepted: requirement,
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

    paid = execute(c, id, %{payment_signature: payment |> Jason.encode!() |> Base.encode64()})

    assert paid["status"] == 200
    assert paid["body"]["status"] == "applied"
    assert_receive :settled
    recovered = get(c, id)
    assert recovered["status"] == 200
    assert recovered["body"]["receipt"] == paid["body"]["receipt"]
    again = execute(c, id)
    assert again["body"]["receipt"] == paid["body"]["receipt"]
    refute_receive :settled, 100
    report = Patchbay.Forum.get_report!(prepared["body"]["report_id"])
    assert report.browser_session_id == nil
    profile = Identity.get_profile!(report.author_profile_id)
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
    assert Watch.confirm() == {:ok, 0}

    assert Patchbay.Forum.get_report!(report.id).escrow_status ==
             :credit_submitted

    # A post funded for another amount is not this bounty's confirmation.
    Agent.update(c.chain, fn _ -> {c.address, 2_000_000, 1, @funded_at} end)
    assert Watch.confirm() == {:ok, 0}

    assert Patchbay.Forum.get_report!(report.id).escrow_status ==
             :credit_submitted

    # The contract's record for this post, from this payer, for this amount.
    Agent.update(c.chain, fn _ -> {c.address, 1_000_000, 1, @funded_at} end)
    assert Watch.confirm() == {:ok, 1}
    confirmed = Patchbay.Forum.get_report!(report.id)
    assert confirmed.escrow_status == :credited
    assert DateTime.to_unix(confirmed.escrow_funded_at) == @funded_at

    assert get(c, id)["body"]["result"]["credit_confirmation"] == "confirmed"

    refute_receive :settled, 100

    assert get(c.other, id)["status"] == 404
    assert execute(c.other, id)["status"] == 404
    assert get(c, id)["body"]["receipt"] == paid["body"]["receipt"]
    refute_receive :settled, 100

    # A different actual signing key cannot use this receipt to read the intent.
    other = %{c | key: :crypto.strong_rand_bytes(32)}
    assert get(other, id)["status"] == 401
  end

  test "changed body and replay are refused by cryptographic verification", c do
    body =
      prepare_body(%{
        amount_usdc: "1.00",
        origin: c.origin,
        tool_name: "fixture",
        verdict: "unknown"
      })

    request = signed(c, "POST", @intents, body)
    assert send_signed(c, request)["status"] == 201
    assert send_signed(c, request)["status"] == 401

    # The same signature cannot cover different JSON.
    assert send_signed(c, %{request | body: "{}"})["status"] == 401

    # Even a valid signature over a bodyless envelope cannot authorize parsed JSON.
    bodyless = signed(c, "POST", @intents, nil)
    assert send_signed(c, %{bodyless | body: body})["status"] == 401
  end

  test "chunked JSON captures exact bytes and cookies confer no authority", c do
    body =
      prepare_body(%{
        amount_usdc: "1.00",
        origin: c.origin,
        tool_name: "fixture",
        verdict: "unknown"
      })

    request = signed(c, "POST", @intents, body)
    headers = Map.put(request.headers, "cookie", "unrelated_browser_cookie=ignored")
    <<first::binary-size(10), rest::binary>> = body

    assert send_signed(c, %{request | headers: headers, body: Stream.map([first, rest], & &1)})[
             "status"
           ] == 201

    too_large = Jason.encode!(%{note: String.duplicate("a", 100_001)})
    assert send_signed(c, %{request | headers: headers, body: too_large})["status"] == 413
  end

  defp issue_receipt(secret, address) do
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

  defp prepare(c, args), do: send_signed(c, signed(c, "POST", @intents, prepare_body(args)))

  defp execute(c, id, fields \\ %{}),
    do: send_signed(c, signed(c, "POST", "#{@intents}/#{id}/execute", Jason.encode!(fields)))

  defp get(c, id), do: send_signed(c, signed(c, "GET", "#{@intents}/#{id}", nil))

  defp prepare_body(args), do: Jason.encode!(%{kind: "special_post", args: args})

  # A request signed the way an agent's own client signs it: the shared SIWA
  # library covers the method, path, receipt, wallet and body digest with the
  # wallet's personal_sign signature.
  defp signed(c, method, path, body) do
    signer =
      Siwa.LocalSigner.from_private_key(Base.encode16(c.key, case: :lower), nil,
        address: c.address
      )

    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{method: method, path: path, headers: %{}, body: body},
        c.receipt,
        signer,
        secret: c.secret,
        audience: "patchbay",
        wallet_audiences: ["patchbay"]
      )

    request
  end

  defp send_signed(c, request) do
    content_type = if request.body, do: %{"content-type" => "application/json"}, else: %{}

    {:ok, response} =
      Req.request(
        method: request.method |> String.downcase() |> String.to_existing_atom(),
        url: c.app <> request.path,
        headers:
          request.headers |> Map.merge(content_type) |> Map.put("accept", "application/json"),
        body: request.body,
        retry: false
      )

    %{"status" => response.status, "body" => response.body}
    |> Map.merge(
      case Req.Response.get_header(response, "payment-required") do
        [terms] -> %{"payment_required" => terms}
        [] -> %{}
      end
    )
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
end
