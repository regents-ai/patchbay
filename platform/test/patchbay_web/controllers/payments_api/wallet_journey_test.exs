defmodule PatchbayWeb.PaymentsAPI.WalletJourneyTest do
  # Everything runs in this test's own database transaction: the product
  # server below answers each request through it, and it is rolled back at
  # the end.
  use Patchbay.DataCase, async: false
  use AshOban.Test, repo: Patchbay.Repo
  use ExUnitProperties
  import Plug.Conn
  alias Patchbay.Forum.Report
  alias Patchbay.Identity
  alias PatchbayWeb.SignedAgent

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
    old_siwa = Application.fetch_env!(:regent_agents, :siwa)
    old_req_options = Application.fetch_env!(:regent_agents, :req_options)
    Application.put_env(:regent_agents, :siwa, Keyword.put(old_siwa, :url, broker))
    Application.put_env(:regent_agents, :req_options, [])

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

    # Both wallets are agents paired with a person, each with their own.
    %{owner: person} = SignedAgent.pair!(nil, address)
    SignedAgent.pair!(nil, other_address)

    on_exit(fn ->
      Application.put_env(:regent_agents, :siwa, old_siwa)
      Application.put_env(:regent_agents, :req_options, old_req_options)
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
      person: person,
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
    assert profile.privy_user_id == nil
    # Payment received and bounty confirmed are two facts: the credit was
    # handed to Base, and nothing is confirmed until the contract says so.
    assert report.escrow_status == :credit_submitted
    assert report.escrow_funded_at == nil
    assert paid["body"]["credit_confirmation"] == "pending"
    assert paid["body"]["status_url"] =~ "/api/agent/payment_intents/#{id}"
    assert paid["body"]["next_action"] =~ "Do not pay again"

    # The contract has no post yet: still waiting, nothing sent again.
    assert %{failure: 0} = confirm_sweep()

    assert Patchbay.Forum.get_report!(report.id).escrow_status ==
             :credit_submitted

    # A post funded for another amount is not this bounty's confirmation.
    Agent.update(c.chain, fn _ -> {c.address, 2_000_000, 1, @funded_at} end)
    assert %{failure: 0} = confirm_sweep()

    assert Patchbay.Forum.get_report!(report.id).escrow_status ==
             :credit_submitted

    # The contract's record for this post, from this payer, for this amount.
    Agent.update(c.chain, fn _ -> {c.address, 1_000_000, 1, @funded_at} end)
    assert %{failure: 0} = confirm_sweep()
    confirmed = Patchbay.Forum.get_report!(report.id)
    assert confirmed.escrow_status == :credited
    assert DateTime.to_unix(confirmed.escrow_funded_at) == @funded_at

    assert get(c, id)["body"]["result"]["credit_confirmation"] == "confirmed"

    # The five-minute sweep leaves a bounty the contract still holds alone,
    # and writes down one the contract has already sent back.
    assert %{failure: 0} = refund_sweep()
    assert Patchbay.Forum.get_report!(report.id).escrow_status == :credited

    Agent.update(c.chain, fn _ -> {c.address, 1_000_000, 3, @funded_at} end)
    assert %{failure: 0} = refund_sweep()
    assert Patchbay.Forum.get_report!(report.id).escrow_status == :refunded

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

  # PB-17: a paired agent pays from its own wallet on every surface. The
  # hosted tools at /mcp call the same door as /api/agent/payment_intents (a
  # page's tools send those very requests), so each step answers alike.
  test "a paired agent pays from its own wallet through /mcp, and every door answers alike", c do
    args = %{
      "amount_usdc" => "2.50",
      "origin" => c.origin,
      "tool_name" => "fixture",
      "verdict" => "unknown"
    }

    prepared = mcp(c, "post_priority_report", %{"kind" => "special_post", "args" => args})
    assert {:ok, %{"id" => id, "amount_usdc" => "2.50", "kind" => "special_post"}} = prepared
    {:ok, %{"escrow_address" => escrow}} = prepared
    assert escrow == String.duplicate("c", 40) |> then(&("0x" <> &1))

    # The terms freeze the agent's own wallet as the one that pays.
    intent = Ash.get!(RegentPayments.PaymentIntent, id, authorize?: false)

    assert intent.payload["__regent_payments_agent_authority"]["wallet_address"] ==
             String.downcase(c.address)

    # Reading back: the same body at both doors.
    assert mcp(c, "get_payment_status", %{"payment_intent_id" => id}) ==
             {:ok, get(c, id)["body"]}

    # The x402 terms: the same at both doors, for exactly the frozen amount,
    # paid to the escrow, whatever the caller sends.
    challenge = execute(c, id)
    assert challenge["status"] == 402
    assert {:ok, offered} = mcp(c, "execute_payment", %{"payment_intent_id" => id})
    assert offered == challenge["body"]
    assert offered["status"] == "payment_required"
    [requirement] = offered["payment_terms"]["accepts"]
    assert requirement["amount"] == "2500000"
    assert String.downcase(requirement["payTo"]) == escrow

    # A payment the agent's person signed is not the agent's: nothing settles.
    assert {:ok, refused} =
             mcp(c, "execute_payment", %{
               "payment_intent_id" => id,
               "payment_signature" => payment(c, requirement, c.person.wallet_address)
             })

    assert refused["status"] == "payment_required"
    assert refused["reason"] =~ "different wallet"
    refute_receive :settled, 100

    # The agent's own signed payment settles once, through /mcp.
    paid_with = payment(c, requirement, c.address)

    assert {:ok, paid} =
             mcp(c, "execute_payment", %{
               "payment_intent_id" => id,
               "payment_signature" => paid_with
             })

    assert paid["status"] == "applied"
    assert_receive :settled
    assert mcp(c, "get_payment_status", %{"payment_intent_id" => id}) == {:ok, get(c, id)["body"]}

    # The same payment again, at either door, answers with the same receipt.
    again = execute(c, id, %{payment_signature: paid_with})
    assert again["body"]["receipt"] == paid["receipt"]

    assert {:ok, %{"receipt" => receipt}} =
             mcp(c, "execute_payment", %{"payment_intent_id" => id})

    assert receipt == paid["receipt"]
    refute_receive :settled, 100

    # Another agent can neither read nor pay these terms, at either door.
    for door <- [&get(c.other, &1)["body"], &execute(c.other, &1)["body"]] do
      assert %{"error" => %{"code" => "not_found"}} = door.(id)
    end

    assert {:error, %{"error" => %{"code" => "not_found"}}} =
             mcp(c.other, "get_payment_status", %{"payment_intent_id" => id})

    assert {:error, %{"error" => %{"code" => "not_found"}}} =
             mcp(c.other, "execute_payment", %{
               "payment_intent_id" => id,
               "payment_signature" => payment(c.other, requirement, c.other.address)
             })

    # Finishing another's payment is refused as finishing one that never was.
    refused = complete(c.other, id)
    assert refused["status"] == 422
    assert refused == complete(c.other, Ecto.UUID.generate())
    refute_receive :settled, 100
  end

  test "a paid assist is prepared at /mcp with the fixed fee, and refused alike at both doors when not set up",
       c do
    request = %{
      "goal" => "Amend a booking.",
      "site_url" => "https://quiet.example.net",
      "sign_in" => "none"
    }

    over_http =
      send_signed(
        c,
        signed(c, "POST", @intents, Jason.encode!(%{kind: "jev_assist", args: request}))
      )

    assert {:error, refusal} =
             mcp(c, "request_assist", %{"kind" => "jev_assist", "args" => request})

    assert over_http["status"] == 503
    assert refusal == over_http["body"]

    Application.put_env(:patchbay, :assist, pay_to_address: "0x" <> String.duplicate("d", 40))
    on_exit(fn -> Application.delete_env(:patchbay, :assist) end)

    assert {:ok, prepared} =
             mcp(c, "request_assist", %{"kind" => "jev_assist", "args" => request})

    assert prepared["amount_usdc"] == "0.10"

    assert {:ok, %{"payment_terms" => %{"accepts" => [requirement]}}} =
             mcp(c, "execute_payment", %{"payment_intent_id" => prepared["id"]})

    assert requirement["amount"] == "100000"
    assert String.downcase(requirement["payTo"]) == "0x" <> String.duplicate("d", 40)
  end

  # Whatever amount an agent asks for within a report's bounds, the terms it is
  # handed, at /mcp as over HTTP, hold exactly that amount and nothing else.
  property "the terms hold exactly the amount asked, at either door", c do
    check all(
            atomic <- integer(1_000_000..100_000_000),
            places <- integer(0..6),
            max_runs: 12
          ) do
      written = written(atomic, places)

      args = %{
        "amount_usdc" => written,
        "origin" => c.origin,
        "tool_name" => "fixture",
        "verdict" => "unknown"
      }

      over_http = prepare(c, args)
      at_mcp = mcp(c, "post_priority_report", %{"kind" => "special_post", "args" => args})

      if rem(atomic, Integer.pow(10, 6 - places)) == 0 do
        assert over_http["status"] == 201
        assert {:ok, prepared} = at_mcp
        assert prepared["amount_usdc"] == over_http["body"]["amount_usdc"]
        assert prepared["amount_usdc"] == RegentPayments.USDC.format(atomic)

        for id <- [prepared["id"], over_http["body"]["id"]] do
          assert {:ok, %{"payment_terms" => %{"accepts" => [requirement]}}} =
                   mcp(c, "execute_payment", %{"payment_intent_id" => id})

          assert requirement["amount"] == Integer.to_string(atomic)
        end
      else
        # Written with fewer places than the amount has: a different, smaller
        # amount was asked for, and it is what the terms hold.
        assert {:ok, prepared} = at_mcp
        assert prepared["amount_usdc"] == over_http["body"]["amount_usdc"]
      end
    end
  end

  test "an amount outside a report's bounds is refused alike at both doors", c do
    for written <- ["0.999999", "100.000001", "1.0000001", "-1.00", "1e2"] do
      args = %{
        "amount_usdc" => written,
        "origin" => c.origin,
        "tool_name" => "fixture",
        "verdict" => "unknown"
      }

      over_http = prepare(c, args)
      assert over_http["status"] == 422, written

      assert {:error, refusal} =
               mcp(c, "post_priority_report", %{"kind" => "special_post", "args" => args})

      assert refusal == over_http["body"], written
    end
  end

  # The minute sweep that asks Base about each bounty waiting to be confirmed.
  defp confirm_sweep, do: schedule_and_run_triggers({Report, :read_escrow_credit})

  # The five-minute sweep that asks Base whether each held bounty has gone back.
  defp refund_sweep, do: schedule_and_run_triggers({Report, :read_escrow_refund})

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

  defp complete(c, id),
    do: send_signed(c, signed(c, "POST", "#{@intents}/#{id}/complete", "{}"))

  # A hosted tool call at /mcp, the whole request signed with the agent's own
  # key: `{:ok, answer}`, or `{:error, refusal}` with the refusal's JSON.
  defp mcp(c, name, arguments) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })

    %{"status" => 200, "body" => %{"result" => result}} =
      send_signed(c, signed(c, "POST", "/mcp", body))

    case result do
      %{"isError" => true, "content" => [%{"text" => text}]} -> {:error, Jason.decode!(text)}
      %{"structuredContent" => answer} -> {:ok, answer}
    end
  end

  # An x402 payment for `requirement`, its authorization from `from`. Only the
  # loopback payment service reads it; it never reaches a chain.
  defp payment(c, requirement, from) do
    %{
      x402Version: 2,
      accepted: requirement,
      payload: %{
        signature: sign(c.key, "synthetic payment checked only by loopback facilitator"),
        authorization: %{
          from: from,
          to: requirement["payTo"],
          value: requirement["amount"],
          validAfter: "0",
          validBefore: Integer.to_string(System.system_time(:second) + 60),
          nonce: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        }
      }
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  # `atomic` millionths written with `places` decimal places, cut, not rounded.
  defp written(atomic, places) do
    whole = div(atomic, 1_000_000)
    fraction = atomic |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")

    if places == 0,
      do: Integer.to_string(whole),
      else: "#{whole}.#{String.slice(fraction, 0, places)}"
  end

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
