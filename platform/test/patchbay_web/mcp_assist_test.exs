defmodule PatchbayWeb.MCPAssistTest do
  @moduledoc """
  Buying an assist over the hosted MCP door and reading it back as the wallet
  that paid: the terms come back at the fixed fee, asking again is the same
  purchase, one payment opens one run for that wallet alone, the read never
  pays, a second assist waits for the first, and a request Patchbay would not
  act on is refused before anyone is asked to pay.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  require Ash.Query

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias Patchbay.Payments.PaymentIntent

  @wallet "0x" <> String.duplicate("d", 40)

  @request %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "sign_in" => "unknown",
    "expected_result" => "A confirmation with a booking reference",
    "believed_calls" => [%{"tool" => "reserve_table", "arguments" => %{"party" => 2}}]
  }

  setup do
    {key, address} = wallet()
    {other_key, other_address} = wallet()

    payment =
      server(:mcp_assist_payment, fn conn, _ ->
        {:ok, _raw, conn} = read_body(conn)

        case conn.request_path do
          "/verify" ->
            answer(conn, 200, %{isValid: true})

          "/settle" ->
            answer(conn, 200, %{
              success: true,
              transaction: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
              network: "eip155:8453"
            })
        end
      end)

    old_assist = Application.get_env(:patchbay, :assist)
    old_facilitator = Application.fetch_env!(:patchbay, Patchbay.Payments.Facilitator)
    Application.put_env(:patchbay, :assist, pay_to_address: @wallet)
    replace_facilitator(Keyword.merge(old_facilitator, url: payment, auth: nil))

    on_exit(fn ->
      Application.put_env(:patchbay, :assist, old_assist)
      replace_facilitator(old_facilitator)
    end)

    %{key: key, address: address, other: %{key: other_key, address: other_address}}
  end

  test "a wallet buys an assist at the fixed fee over MCP and reads its run back alone", c do
    args = Map.put(@request, "wallet_address", c.address)

    offered = call(c.conn, "request_assist", args)
    assert offered["isError"] == true
    terms = offered["structuredContent"]
    assert terms["error"] == "Payment is required to open this assist."

    assert [%{"amount" => "100000", "payTo" => @wallet, "network" => "eip155:8453"}] =
             terms["accepts"]

    handoff = handoff_of(offered)
    id = handoff["payment_intent_id"]
    assert handoff["amount_usdc"] == "0.10"
    assert handoff["if_your_client_cannot_pay"] =~ "patchbay payments execute #{id}"

    # Asking again is the same purchase, not a second one.
    assert handoff_of(call(c.conn, "request_assist", args))["payment_intent_id"] == id
    profile = Identity.get_wallet_profile!(8453, String.downcase(c.address))
    assert intents_of(profile) == 1

    # Paid: the run is open for this wallet, and the answer says where to read it.
    paid = call(c.conn, "request_assist", args, payment(c, terms))
    assert paid["isError"] == false
    answer = paid["structuredContent"]
    assert answer["status"] == "applied"
    assert answer["amount_usdc"] == "0.10"
    assert answer["run_status"] == "paid"
    assert answer["assist_tool"] == "get_assist"
    assert answer["next_action"] =~ "Do not pay again"
    run_id = answer["run_id"]
    assert paid["_meta"]["x402/payment-response"]["success"] == true

    read = call(c.conn, "get_assist", %{"run_id" => run_id, "wallet_address" => c.address})
    assert read["isError"] == false
    assert read["structuredContent"]["run_id"] == run_id
    assert read["structuredContent"]["goal"] == @request["goal"]
    assert read["structuredContent"]["fee_deposit"] == %{"status" => "pending", "tx_hash" => nil}
    assert read["structuredContent"]["next_action"] =~ "working on it"

    # Another wallet, even one that has paid before, is told there is no such assist.
    _other_terms =
      call(c.conn, "request_assist", Map.put(@request, "wallet_address", c.other.address))

    other = call(c.conn, "get_assist", %{"run_id" => run_id, "wallet_address" => c.other.address})
    assert other["isError"] == true
    assert other["structuredContent"]["problem_code"] == "not_found"

    # A second assist waits for the first; nothing is prepared and nothing paid.
    second = call(c.conn, "request_assist", Map.put(args, "goal", "Cancel the same table"))
    assert second["isError"] == true
    assert second["structuredContent"]["problem_code"] == "assist_running"
    assert second["structuredContent"]["run_id"] == run_id
    assert intents_of(profile) == 1

    # Once the first is answered, the same wallet may ask again.
    # The test closes the run the way the worker does, as nobody in particular.
    {:ok, run} = Assist.get_run(run_id, authorize?: false)
    {:ok, running} = Assist.start_run(run, authorize?: false)

    {:ok, _done} =
      Assist.finish_run(running, %{status: :finished, outcome: :reached}, authorize?: false)

    again = call(c.conn, "request_assist", Map.put(args, "goal", "Cancel the same table"))
    assert again["structuredContent"]["x402Version"] == 2
    assert intents_of(profile) == 2
  end

  test "a request Patchbay would not act on is refused before anyone pays", c do
    signed_in =
      @request
      |> Map.put("wallet_address", c.address)
      |> Map.put("sign_in", "required")

    refused = call(c.conn, "request_assist", signed_in)
    assert refused["isError"] == true
    assert refused["structuredContent"]["problem_code"] == "needs_sign_in"
    assert refused["structuredContent"]["error"] =~ "Nothing was charged"

    private =
      @request
      |> Map.put("wallet_address", c.address)
      |> Map.put("site_url", "http://bookings.example.com/app")

    assert call(c.conn, "request_assist", private)["structuredContent"]["problem_code"] ==
             "invalid"

    # The door checks the shape before the request is read: calls are objects.
    shapeless = Map.put(@request, "wallet_address", c.address)

    %{"error" => %{"message" => message}} =
      c.conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            "name" => "request_assist",
            "arguments" => Map.put(shapeless, "believed_calls", ["reserve_table"])
          }
        })
      )
      |> json_response(200)

    assert message == "believed_calls must be a list of objects."

    # Nothing was prepared for any of them.
    profile = Identity.get_wallet_profile!(8453, String.downcase(c.address))
    assert intents_of(profile) == 0

    # With no wallet set for the fee, assists are not on offer here.
    Application.put_env(:patchbay, :assist, pay_to_address: nil)
    off = call(c.conn, "request_assist", Map.put(@request, "wallet_address", c.address))
    assert off["structuredContent"]["problem_code"] == "not_configured"
    assert off["structuredContent"]["error"] =~ "assists"
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

  defp wallet do
    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    {key, Siwa.EvmPersonalSign.public_key_to_address(public)}
  end

  defp payment(%{key: key, address: address}, terms) do
    [requirement] = terms["accepts"]

    {:ok, signature} =
      Siwa.EvmPersonalSign.sign_personal_signature(
        Base.encode16(key, case: :lower),
        "synthetic payment checked only by the loopback payment service"
      )

    %{
      "x402Version" => 2,
      "accepted" => requirement,
      "extensions" => terms["extensions"],
      "payload" => %{
        "signature" => signature,
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

  # The fake payment service

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
