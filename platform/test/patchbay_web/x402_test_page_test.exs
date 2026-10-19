defmodule PatchbayWeb.X402TestPageTest do
  @moduledoc """
  The Wallet Bench's paid-call test page: 0.01 USDC by x402 to the Bench's
  funder wallet, answered "test passed" only once the payment has settled.
  """

  # Each test points the site's one payment client at its own stand-in.
  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias X402.Client
  alias X402.PaymentRequired
  alias X402.PaymentResponse
  alias X402.Signer.LocalKey

  @path "/bench/x402-test"
  @funder "0x786C67651BcB148f5A383A150E78bD4Ed9f64f7b"
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @settled "0x" <> String.duplicate("1", 64)

  setup do
    test = self()
    {:ok, settles?} = Agent.start_link(fn -> true end)

    # The payment service: it finds every payment valid, says each time it is
    # asked, and settles or not as the test set it.
    service =
      server(fn conn, _opts ->
        {:ok, _body, conn} = read_body(conn)

        case conn.request_path do
          "/verify" ->
            send(test, :asked_to_verify)
            answer(conn, %{isValid: true})

          "/settle" ->
            send(test, :asked_to_settle)

            if Agent.get(settles?, & &1),
              do: answer(conn, %{success: true, transaction: @settled, network: "eip155:8453"}),
              else:
                answer(conn, %{
                  success: false,
                  errorReason: "insufficient_funds",
                  transaction: "",
                  network: "eip155:8453"
                })
        end
      end)

    Patchbay.PaymentService.stand_in(service)
    {:ok, wallet} = LocalKey.new(:crypto.strong_rand_bytes(32))

    %{wallet: wallet, settles?: settles?}
  end

  test "an unpaid request is answered 402 with the fixed terms, and never with the paid answer",
       %{conn: conn} do
    unpaid = get(conn, @path)

    assert unpaid.status == 402

    assert %{
             "x402Version" => 2,
             "accepts" => [
               %{
                 "scheme" => "exact",
                 "network" => "eip155:8453",
                 "asset" => @usdc,
                 "amount" => "10000",
                 "payTo" => @funder
               }
             ]
           } = terms(unpaid)

    refute unpaid.resp_body =~ "test passed"
    refute_received :asked_to_verify
  end

  test "a payment that settles is answered \"test passed\", and the same payment sent again is not",
       %{conn: conn, wallet: wallet} do
    paid = pay(conn, wallet, terms(get(conn, @path)))

    assert json_response(paid, 200) == %{"message" => "test passed"}
    assert_received :asked_to_verify
    assert_received :asked_to_settle

    assert [receipt] = get_resp_header(paid, "payment-response")

    assert {:ok, %{"success" => true, "transaction" => @settled}} =
             PaymentResponse.decode(receipt)

    # The same payment sent again is refused here, without asking the service.
    [payment] = get_req_header(paid, "payment-signature")
    again = conn |> recycle() |> put_req_header("payment-signature", payment) |> get(@path)

    assert again.status == 402
    refute again.resp_body =~ "test passed"
    refute_received :asked_to_verify
  end

  test "a payment that is found valid but does not settle never gets the paid answer",
       %{conn: conn, wallet: wallet, settles?: settles?} do
    Agent.update(settles?, fn _ -> false end)

    unsettled = pay(conn, wallet, terms(get(conn, @path)))

    assert_received :asked_to_settle
    assert unsettled.status == 402
    refute unsettled.resp_body =~ "test passed"
  end

  test "a payment that is malformed, made out to another wallet, or for another amount, is refused without asking the payment service",
       %{conn: conn, wallet: wallet} do
    %{"accepts" => [fixed]} = offered = terms(get(conn, @path))
    {:ok, other} = LocalKey.new(:crypto.strong_rand_bytes(32))

    malformed =
      conn |> recycle() |> put_req_header("payment-signature", "not a payment") |> get(@path)

    wrong =
      for changed <- [%{fixed | "payTo" => other.address}, %{fixed | "amount" => "1"}],
          do: pay(conn, wallet, %{offered | "accepts" => [changed]})

    for refused <- [malformed | wrong] do
      assert refused.status in [400, 402]
      refute refused.resp_body =~ "test passed"
    end

    refute_received :asked_to_verify
    refute_received :asked_to_settle
  end

  # The terms an unpaid answer offered.
  defp terms(conn) do
    assert [header] = get_resp_header(conn, "payment-required")
    assert {:ok, terms} = PaymentRequired.decode(header)
    terms
  end

  # The same request again, carrying `wallet`'s signed payment of `terms`.
  defp pay(conn, wallet, terms) do
    {:ok, payment} = Client.build_payment(terms, wallet)
    {:ok, header} = Client.encode_payment(payment)

    conn |> recycle() |> put_req_header("payment-signature", header) |> get(@path)
  end

  defp server(plug) do
    server = start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp answer(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
end
