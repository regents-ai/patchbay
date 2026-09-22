defmodule PatchbayWeb.MCPPaymentTest do
  @moduledoc """
  Paying for a priority report over the hosted MCP door, and acting on it as
  the wallet that paid: the terms come back as the x402 MCP transport says, a
  payment from any other wallet is refused, one payment settles once however
  often the call is repeated, the status read never pays, and the wallet
  actions on the report go through only for that wallet's own signature.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias Patchbay.Payments.PaymentIntent
  alias Patchbay.Repo
  alias PatchbayWeb.Plugs.CurrentProfile

  @escrow "0x" <> String.duplicate("c", 40)

  setup do
    {key, address} = wallet()
    {other_key, other_address} = wallet()
    owner = self()
    # What the fake payment service does with a settlement: settles it, or
    # leaves it hanging as a settlement still pending.
    {:ok, settlement} = Agent.start_link(fn -> :settles end)

    payment =
      server(:mcp_payment, fn conn, _ ->
        {:ok, raw, conn} = read_body(conn)
        request = Jason.decode!(raw)

        case conn.request_path do
          "/verify" ->
            answer(conn, 200, %{isValid: true})

          "/settle" ->
            case Agent.get(settlement, & &1) do
              :settles ->
                send(owner, :settled)

                # A payment service never reports one transaction twice, and
                # a receipt is refused for a hash already written down.
                answer(conn, 200, %{
                  success: true,
                  transaction: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                  network: "eip155:8453"
                })

              :pending ->
                answer(conn, 200, %{success: false, errorReason: "settlement_pending"})
            end

          "/rpc" ->
            answer(conn, 200, rpc(request))
        end
      end)

    old_escrow = Application.get_env(:patchbay, :escrow)
    old_facilitator = Application.fetch_env!(:patchbay, Patchbay.Payments.Facilitator)

    Application.put_env(:patchbay, :escrow,
      contract_address: @escrow,
      operator_private_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      rpc_url: payment <> "/rpc"
    )

    replace_facilitator(Keyword.merge(old_facilitator, url: payment, auth: nil))

    on_exit(fn ->
      Application.put_env(:patchbay, :escrow, old_escrow)
      replace_facilitator(old_facilitator)
    end)

    %{
      key: key,
      address: address,
      other: %{key: other_key, address: other_address},
      settlement: settlement,
      origin: "https://mcp-#{Ecto.UUID.generate()}.invalid"
    }
  end

  test "a wallet pays once over MCP, reads the payment back, and acts on its report by signing",
       c do
    report_args = %{
      "wallet_address" => c.address,
      "origin" => c.origin,
      "tool_name" => "fixture",
      "verdict" => "unknown",
      "note" => "Untrusted fixture evidence",
      "amount_usdc" => "1.00"
    }

    # The terms, as the x402 MCP transport carries them, with the handoff for
    # a client that cannot pay here as a second text block.
    offered = call(c.conn, "post_priority_report", report_args)
    assert offered["isError"] == true
    terms = offered["structuredContent"]
    assert terms["x402Version"] == 2

    assert [%{"amount" => "1000000", "payTo" => @escrow, "network" => "eip155:8453"}] =
             terms["accepts"]

    assert is_binary(terms["extensions"]["paymentIdentifier"])
    [%{"text" => terms_text}, %{"text" => handoff_text}] = offered["content"]
    assert Jason.decode!(terms_text) == terms
    handoff = Jason.decode!(handoff_text)
    id = handoff["payment_intent_id"]
    assert handoff["status"] == "payment_required"
    assert handoff["status_tool"] == "get_payment_status"
    assert handoff["if_your_client_cannot_pay"] =~ "patchbay payments execute #{id}"
    assert handoff["status_url"] =~ "/api/agent/payment_intents/#{id}"

    # Asking again is the same purchase, not a second one.
    again = call(c.conn, "post_priority_report", report_args)
    assert handoff_of(again)["payment_intent_id"] == id
    profile = Identity.get_wallet_profile!(8453, String.downcase(c.address))
    assert intents_of(profile) == 1

    # A payment signed by another wallet does not buy in this wallet's name.
    other_pays = call(c.conn, "post_priority_report", report_args, payment(c.other, terms))
    assert other_pays["isError"] == true
    assert other_pays["structuredContent"]["error"] =~ "different wallet"
    assert handoff_of(other_pays)["reason"] =~ "different wallet"
    refute_receive :settled, 100

    # The wallet's own payment settles once and publishes the report under it.
    paid = call(c.conn, "post_priority_report", report_args, payment(c, terms))
    refute paid["isError"]
    assert paid["_meta"]["x402/payment-response"]["success"] == true
    applied = paid["structuredContent"]
    assert applied["status"] == "applied"
    assert applied["payment_intent_id"] == id
    assert applied["credit_confirmation"] == "pending"
    assert applied["next_action"] =~ "Do not pay again"
    assert_receive :settled

    report = Forum.get_report!(applied["report_id"])
    assert report.author_profile_id == profile.id
    assert report.browser_session_id == nil
    assert report.escrow_status == :credit_submitted

    # Paying again, as an x402 client that retries would, changes nothing.
    replay = call(c.conn, "post_priority_report", report_args, payment(c, terms))
    refute replay["isError"]
    assert replay["structuredContent"]["receipt"] == applied["receipt"]
    assert replay["_meta"]["x402/payment-response"]["success"] == true
    refute_receive :settled, 100
    assert intents_of(profile) == 1

    # Reading the payment back is the wallet's own, and never pays.
    status =
      call(c.conn, "get_payment_status", %{
        "payment_intent_id" => id,
        "wallet_address" => c.address
      })

    refute status["isError"]
    assert status["structuredContent"]["status"] == "applied"
    assert status["structuredContent"]["receipt"] == applied["receipt"]
    assert status["structuredContent"]["result"]["report_id"] == report.id

    other_reads =
      call(c.conn, "get_payment_status", %{
        "payment_intent_id" => id,
        "wallet_address" => c.other.address
      })

    assert other_reads["structuredContent"]["problem_code"] == "not_found"
    refute_receive :settled, 100

    # Somebody signed in on a page answers; accepting that answer takes the
    # wallet's signature over exactly this action, not just its address.
    answerer =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:mcp-answerer-" <> Ecto.UUID.generate(),
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    %{"reply_id" => reply_id} =
      c.conn
      |> get("/")
      |> recycle()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), answerer.id)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/forum/threads/#{report.id}/replies",
        Jason.encode!(%{
          "body_markdown" => "Retry with a smaller page.",
          "reply_kind" => "answer"
        })
      )
      |> json_response(201)

    accept_args = %{
      "report_id" => report.id,
      "reply_id" => reply_id,
      "wallet_address" => c.address
    }

    unsigned = call(c.conn, "accept_solution", accept_args)
    assert unsigned["isError"] == true

    %{
      "problem_code" => "signature_required",
      "challenge" => challenge,
      "typed_data" => typed_data
    } =
      unsigned["structuredContent"]

    assert typed_data["message"]["action"] == "accept_solution"
    assert typed_data["message"]["reportId"] == report.id
    assert typed_data["message"]["replyId"] == reply_id
    assert String.downcase(typed_data["message"]["wallet"]) == String.downcase(c.address)
    assert report.accepted_reply_id == nil

    forged =
      call(
        c.conn,
        "accept_solution",
        Map.merge(accept_args, %{
          "challenge" => challenge,
          "signature" => sign_typed(c.other.key, typed_data)
        })
      )

    assert forged["structuredContent"]["problem_code"] == "other_wallet"
    assert Forum.get_report!(report.id).accepted_reply_id == nil

    accepted =
      call(
        c.conn,
        "accept_solution",
        Map.merge(accept_args, %{
          "challenge" => challenge,
          "signature" => sign_typed(c.key, typed_data)
        })
      )

    refute accepted["isError"]
    assert accepted["structuredContent"]["accepted"] == true
    assert accepted["structuredContent"]["reply_id"] == reply_id
    assert accepted["structuredContent"]["escrow_status"] == "released"
    assert accepted["structuredContent"]["release_tx_hash"] == "0x" <> String.duplicate("f", 64)
    assert accepted["structuredContent"]["winner"]["profile_id"] == answerer.public_id

    # Asking the bounty back is the same two steps, and a challenge issued
    # for accepting does not sign for withdrawing.
    withdraw_args = %{"report_id" => report.id, "wallet_address" => c.address}

    mismatched =
      call(
        c.conn,
        "withdraw_priority_report",
        Map.merge(withdraw_args, %{
          "challenge" => challenge,
          "signature" => sign_typed(c.key, typed_data)
        })
      )

    assert mismatched["structuredContent"]["problem_code"] == "challenge_mismatch"

    %{"challenge" => refund_challenge, "typed_data" => refund_typed_data} =
      call(c.conn, "withdraw_priority_report", withdraw_args)["structuredContent"]

    assert refund_typed_data["message"]["action"] == "withdraw_priority_report"

    asked =
      call(
        c.conn,
        "withdraw_priority_report",
        Map.merge(withdraw_args, %{
          "challenge" => refund_challenge,
          "signature" => sign_typed(c.key, refund_typed_data)
        })
      )

    refute asked["isError"]
    assert asked["structuredContent"]["asked"] == true
    assert asked["structuredContent"]["refund_tx_hash"] == "0x" <> String.duplicate("f", 64)
  end

  test "terms that ran out are replaced, and an uncertain settlement is never paid again", c do
    report_args = %{
      "wallet_address" => c.address,
      "origin" => c.origin,
      "tool_name" => "fixture",
      "verdict" => "errored",
      "amount_usdc" => "2.00"
    }

    first = handoff_of(call(c.conn, "post_priority_report", report_args))

    Repo.query!(
      "UPDATE payment_intents SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [
        Ecto.UUID.dump!(first["payment_intent_id"])
      ]
    )

    fresh = call(c.conn, "post_priority_report", report_args)
    assert fresh["isError"] == true
    id = handoff_of(fresh)["payment_intent_id"]
    assert id != first["payment_intent_id"]

    # The payment service takes the payment but does not finish settling it:
    # the money may still move, so nothing is refused and nothing is retried.
    Agent.update(c.settlement, fn _ -> :pending end)

    held =
      call(c.conn, "post_priority_report", report_args, payment(c, fresh["structuredContent"]))

    assert held["isError"] == true
    assert held["structuredContent"]["problem_code"] == "settlement_pending"
    assert held["structuredContent"]["payment_intent_id"] == id
    refute_receive :settled, 100

    status =
      call(c.conn, "get_payment_status", %{
        "payment_intent_id" => id,
        "wallet_address" => c.address
      })

    assert status["structuredContent"]["status"] == "settlement_pending"
    assert status["structuredContent"]["recovery_required"] == true

    Agent.update(c.settlement, fn _ -> :settles end)

    again =
      call(c.conn, "post_priority_report", report_args, payment(c, fresh["structuredContent"]))

    assert again["structuredContent"]["problem_code"] == "settlement_pending"
    refute_receive :settled, 100
  end

  test "a wallet has to be a Base address, and a wallet never seen has nothing to read", c do
    refused =
      call(c.conn, "post_priority_report", %{
        "wallet_address" => "0x1234",
        "origin" => c.origin,
        "tool_name" => "fixture",
        "verdict" => "unknown",
        "amount_usdc" => "1.00"
      })

    assert refused["structuredContent"]["problem_code"] == "invalid"
    assert hd(refused["structuredContent"]["errors"]) =~ "wallet_address"

    unseen =
      call(c.conn, "get_payment_status", %{
        "payment_intent_id" => Ecto.UUID.generate(),
        "wallet_address" => c.other.address
      })

    assert unseen["structuredContent"]["problem_code"] == "not_found"

    # A report id that cannot name a report gets no challenge to sign.
    unnamed =
      call(c.conn, "accept_solution", %{
        "report_id" => "not-a-report",
        "reply_id" => Ecto.UUID.generate(),
        "wallet_address" => c.address
      })

    assert unnamed["structuredContent"]["problem_code"] == "not_found"
    refute Map.has_key?(unnamed["structuredContent"], "challenge")

    # A suspended wallet keeps its profile and loses this door.
    {:ok, suspended} = Identity.upsert_from_wallet(%{wallet_address: c.other.address})

    Patchbay.Repo.query!("UPDATE agent_profiles SET status='suspended' WHERE id=$1", [
      Ecto.UUID.dump!(suspended.id)
    ])

    report_args = %{
      "wallet_address" => c.other.address,
      "origin" => c.origin,
      "tool_name" => "fixture",
      "verdict" => "unknown",
      "amount_usdc" => "1.00"
    }

    assert call(c.conn, "post_priority_report", report_args)["structuredContent"]["problem_code"] ==
             "suspended"

    unread =
      call(c.conn, "get_payment_status", %{
        "payment_intent_id" => Ecto.UUID.generate(),
        "wallet_address" => c.other.address
      })

    assert unread["structuredContent"]["problem_code"] == "suspended"
  end

  # Driving the hosted door

  defp call(conn, name, arguments, payment \\ nil) do
    params = %{"name" => name, "arguments" => arguments}
    params = if payment, do: Map.put(params, "_meta", %{"x402/payment" => payment}), else: params

    %{"result" => result} =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: params})
      )
      |> json_response(200)

    result
  end

  defp handoff_of(%{"content" => [_terms, %{"text" => text}]}), do: Jason.decode!(text)

  # The intents standing for a wallet's profile, counted as the test, not as
  # any caller: the count is what the door must not have grown.
  defp intents_of(profile) do
    PaymentIntent
    |> Ash.Query.filter(actor_profile_id == ^profile.id)
    |> Ash.count!(authorize?: false)
  end

  # Signing

  defp wallet do
    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    {key, Siwa.EvmPersonalSign.public_key_to_address(public)}
  end

  defp payment(%{key: key, address: address}, terms) do
    [requirement] = terms["accepts"]

    %{
      "x402Version" => 2,
      "accepted" => requirement,
      "extensions" => terms["extensions"],
      "payload" => %{
        "signature" =>
          sign(key, "synthetic payment checked only by the loopback payment service"),
        "authorization" => %{
          "from" => address,
          "to" => requirement["payTo"],
          "value" => requirement["amount"],
          "validAfter" => "0",
          "validBefore" => Integer.to_string(System.system_time(:second) + 60),
          "nonce" => "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        }
      }
    }
  end

  defp sign(key, message) do
    {:ok, signature} =
      Siwa.EvmPersonalSign.sign_personal_signature(Base.encode16(key, case: :lower), message)

    signature
  end

  # Signs the typed data exactly as the tool handed it out, as a wallet would:
  # the chain id travels as a decimal string in EIP-712 JSON and is a number
  # when hashed.
  defp sign_typed(key, typed_data) do
    domain = typed_data["domain"]

    Ethers.TypedData.new!(
      types: Map.delete(typed_data["types"], "EIP712Domain"),
      primary_type: typed_data["primaryType"],
      domain: [
        name: domain["name"],
        version: domain["version"],
        chain_id: String.to_integer(domain["chainId"])
      ],
      message: typed_data["message"]
    )
    |> Ethers.sign_typed_data!(signer: Ethers.Signer.Local, signer_opts: [private_key: key])
  end

  # The fake payment service and chain

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

  defp rpc(requests) when is_list(requests), do: Enum.map(requests, &rpc/1)

  # A chain that takes every transaction and holds no post yet.
  defp rpc(%{"id" => id, "method" => method}) do
    value =
      case method do
        "eth_call" ->
          "0x" <> Base.encode16(encoded_post(), case: :lower)

        "eth_chainId" ->
          "0x7a69"

        "eth_getTransactionCount" ->
          "0x0"

        "eth_estimateGas" ->
          "0x186a0"

        "eth_gasPrice" ->
          "0x3b9aca00"

        "eth_maxPriorityFeePerGas" ->
          "0x1"

        "eth_feeHistory" ->
          %{
            oldestBlock: "0x0",
            baseFeePerGas: ["0x1", "0x1"],
            gasUsedRatio: [0.5],
            reward: [["0x1"]]
          }

        "eth_sendRawTransaction" ->
          "0x" <> String.duplicate("f", 64)
      end

    %{jsonrpc: "2.0", id: id, result: value}
  end

  defp encoded_post do
    ABI.TypeEncoder.encode(
      [<<0::160>>, 0, 0, 0],
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
