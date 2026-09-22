defmodule PatchbayWeb.AssistAPI.AssistPaymentTest do
  @moduledoc """
  Buying a paid assist: the fee is fixed and frozen with the request, the
  wallet named in the terms is the one this Patchbay is set up with, the run
  opens from the frozen terms once the money settles, only the payer reads
  it back, and every request Patchbay would not act on is refused before
  anyone is asked to pay.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias PatchbayWeb.PaymentsAPI.Purchase
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.Plugs.WalletAuthor

  @facilitator Patchbay.Payments.Facilitator
  @wallet "0x" <> String.duplicate("d", 40)

  @args %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "sign_in" => "unknown",
    "expected_result" => "A confirmation with a booking reference",
    "believed_calls" => [%{"tool" => " reserve_table ", "arguments" => %{"party" => 2}}]
  }

  setup do
    payment =
      server(fn conn, _ ->
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
    old_facilitator = Application.fetch_env!(:patchbay, @facilitator)
    Application.put_env(:patchbay, :assist, pay_to_address: @wallet)
    replace_facilitator(Keyword.merge(old_facilitator, url: payment, auth: nil))

    on_exit(fn ->
      Application.put_env(:patchbay, :assist, old_assist)
      replace_facilitator(old_facilitator)
    end)

    %{payer: profile("a"), other: profile("b")}
  end

  test "a page profile buys an assist at the fixed fee and its run opens for the payer alone",
       c do
    prepared =
      c.payer
      |> signed_in()
      |> post(~p"/api/payment_intents", %{kind: "jev_assist", args: @args})
      |> json_response(201)

    assert prepared["kind"] == "jev_assist"
    assert prepared["amount_usdc"] == "0.10"
    assert prepared["site_url"] == @args["site_url"]
    assert prepared["effect_summary"] =~ "bookings.example.com"
    assert prepared["effect_summary"] =~ "0.10 USDC"
    assert prepared["assist_url"] == url(~p"/api/assists/#{prepared["run_id"]}")
    assert prepared["execute_url"] == url(~p"/api/payment_intents/#{prepared["id"]}/execute")

    # Nothing is open before the money lands.
    assert c.payer |> signed_in() |> get(prepared["assist_url"]) |> json_response(404)

    challenge =
      c.payer |> signed_in() |> post(prepared["execute_url"], %{}) |> json_response(402)

    assert [requirement] = challenge["payment_terms"]["accepts"]
    assert requirement["payTo"] == @wallet
    assert requirement["amount"] == "100000"
    assert requirement["network"] == "eip155:8453"

    applied =
      c.payer
      |> signed_in()
      |> put_req_header("payment-signature", payment(c.payer, challenge["payment_terms"]))
      |> post(prepared["execute_url"], %{})
      |> json_response(200)

    assert applied["status"] == "applied"
    assert applied["run_id"] == prepared["run_id"]
    assert applied["run_status"] == "paid"
    assert applied["result_available"] == true
    assert applied["assist_url"] == prepared["assist_url"]
    assert applied["next_action"] =~ "Do not pay again"

    run = c.payer |> signed_in() |> get(prepared["assist_url"]) |> json_response(200)
    assert run["run_id"] == prepared["run_id"]
    assert run["status"] == "paid"
    assert run["outcome"] == nil
    assert run["goal"] == @args["goal"]
    assert run["site_url"] == @args["site_url"]
    assert run["sign_in"] == "unknown"
    assert run["expected_result"] == @args["expected_result"]
    assert run["believed_calls"] == [%{"tool" => "reserve_table", "arguments" => %{"party" => 2}}]
    assert run["steps"] == []
    assert run["payment_intent_id"] == prepared["id"]

    # The payment reads back with the run it bought.
    read =
      c.payer
      |> signed_in()
      |> get(~p"/api/payment_intents/#{prepared["id"]}")
      |> json_response(200)

    assert read["status"] == "applied"
    assert read["result"]["run_id"] == prepared["run_id"]
    assert read["recovery_required"] == false

    # Another profile cannot tell the run from one that never existed.
    hidden = c.other |> signed_in() |> get(prepared["assist_url"]) |> json_response(404)

    absent =
      c.other
      |> signed_in()
      |> get(~p"/api/assists/#{Ecto.UUID.generate()}")
      |> json_response(404)

    assert hidden == absent

    assert {:ok, %{payer_profile_id: payer_id}} =
             Assist.get_run(prepared["run_id"], actor: c.payer)

    assert payer_id == c.payer.id
    assert {:error, _} = Assist.get_run(prepared["run_id"], actor: c.other)

    # Paying again for the same terms buys nothing twice.
    again =
      c.payer
      |> signed_in()
      |> put_req_header("payment-signature", payment(c.payer, challenge["payment_terms"]))
      |> post(prepared["execute_url"], %{})
      |> json_response(200)

    assert again["status"] == "applied"
    assert again["run_id"] == prepared["run_id"]
  end

  test "requests Patchbay would not act on are refused before anyone is asked to pay", c do
    signed_in_required = Map.put(@args, "sign_in", "required")

    refused =
      c.payer
      |> signed_in()
      |> post(~p"/api/payment_intents", %{kind: "jev_assist", args: signed_in_required})
      |> json_response(422)

    assert refused["problem_code"] == "needs_sign_in"
    assert refused["error"] =~ "Nothing was charged"

    for {bad, words} <- [
          {Map.put(@args, "site_url", "http://bookings.example.com"), "site_url"},
          {Map.put(@args, "site_url", "https://10.0.0.1/app"), "site_url"},
          {Map.put(@args, "site_url", "https://[::1]/app"), "site_url"},
          {Map.put(@args, "site_url", "https://localhost/app"), "site_url"},
          {Map.put(@args, "site_url", "https://localhost./app"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.internal./app"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.interna%6C/app"), "site_url"},
          {Map.put(@args, "site_url", "https://bookings.example.com:6379/app"), "site_url"},
          {Map.put(@args, "site_url", "https://bookings.example.test/app"), "site_url"},
          {Map.put(
             @args,
             "site_url",
             "https://bookings.example.com/" <> String.duplicate("a", 2_048)
           ), "site_url"},
          {Map.put(
             @args,
             "site_url",
             "https://" <> String.duplicate("a", 250) <> ".example.com/"
           ), "site_url"},
          {Map.put(@args, "site_url", "https://intranet"), "site_url"},
          {Map.put(@args, "site_url", "https://vault.internal/app"), "site_url"},
          {Map.put(@args, "site_url", "https://user:pw@bookings.example.com"), "site_url"},
          {Map.put(@args, "goal", String.duplicate("x", 1_001)), "goal"},
          {Map.put(@args, "goal", "   "), "goal"},
          {Map.delete(@args, "expected_result"), "expected_result"},
          {Map.put(@args, "sign_in", "maybe"), "sign_in"},
          {Map.put(@args, "believed_calls", List.duplicate(%{"tool" => "t"}, 6)),
           "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"tool" => "t", "extra" => 1}]), "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"arguments" => %{}}]), "believed_calls"},
          {Map.put(@args, "believed_calls", [%{"tool" => "t", "arguments" => "no"}]),
           "believed_calls"},
          {Map.put(@args, "amount_usdc", "0.10"), "amount_usdc"}
        ] do
      body =
        c.payer
        |> signed_in()
        |> post(~p"/api/payment_intents", %{kind: "jev_assist", args: bad})
        |> json_response(422)

      assert body["problem_code"] == "invalid"
      assert [message] = body["errors"]
      assert String.starts_with?(message, words <> ":")
    end

    # The terms hold the request to the same rules whoever prepares them.
    assert {:error, _} =
             Payments.prepare_jev_assist(%{request: Map.put(@args, "sign_in", "required")},
               actor: c.payer
             )

    assert {:error, _} =
             Payments.prepare_jev_assist(
               %{request: Map.put(@args, "site_url", "http://x.example")},
               actor: c.payer
             )

    assert {:error, _} = Payments.prepare_jev_assist(%{request: @args}, actor: nil)

    Application.put_env(:patchbay, :assist, pay_to_address: " ")

    off =
      c.payer
      |> signed_in()
      |> post(~p"/api/payment_intents", %{kind: "jev_assist", args: @args})
      |> json_response(503)

    assert off["problem_code"] == "not_configured"
    assert off["error"] == "Paid assists are not set up on this Patchbay."
  end

  test "a wallet author's assist is paid and read back through the agent door", c do
    wallet = Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("e", 40)})

    assert {:ok, intent} = Purchase.prepare_jev_assist(wallet, @args)
    assert intent.amount_atomic == 100_000
    assert intent.payload["author_origin"] == "wallet"
    assert intent.payload["pay_to_address"] == @wallet

    assert intent.payload["request"]["believed_calls"] == [
             %{"tool" => "reserve_table", "arguments" => %{"party" => 2}}
           ]

    payload = Purchase.intent_payload(intent)
    assert payload.assist_url == url(~p"/api/agent/assists/#{intent.target_id}")
    assert payload.execute_url == url(~p"/api/agent/payment_intents/#{intent.id}/execute")

    # The wallet door lets the assist through, exactly as it lets a paid report through.
    conn =
      Plug.Test.conn(:post, "/api/agent/payment_intents", "{}")
      |> Map.put(:body_params, %{"kind" => "jev_assist", "args" => @args})
      |> Map.put(:path_info, ["api", "agent", "payment_intents"])
      |> assign(:raw_body, "{}")
      |> put_private(:wallet_body_complete, true)
      |> put_req_header("content-type", "application/json")

    assert {:ok, _} = WalletAuthor.before_verify(conn, %{})

    # A wallet may read its own assist payment back; nobody else can.
    assert {:ok, found} = Purchase.read(wallet, intent.id)
    assert found.kind == :jev_assist
    assert {:error, :not_found} = Purchase.read(c.payer, intent.id)

    # The agent door's read is behind the wallet proof, not a page's cookie.
    cookie_read = c.payer |> signed_in() |> get(~p"/api/agent/assists/#{intent.target_id}")
    assert cookie_read.status in [401, 503]
  end

  test "a settled assist whose run was not opened is opened on the next call", c do
    assert {:ok, intent} = Purchase.prepare_jev_assist(c.payer, @args)

    {:ok, _receipt} =
      Payments.record_payment_receipt(
        %{
          payment_intent_id: intent.id,
          payment_identifier: intent.payment_identifier,
          payer_address: c.payer.wallet_address,
          network: intent.network,
          asset: intent.asset,
          amount_atomic: intent.amount_atomic,
          facilitator: "http://127.0.0.1/fixture",
          transaction_hash: "0x" <> String.duplicate("7", 64),
          payment_response: %{"success" => true},
          settled_at: DateTime.utc_now()
        },
        actor: c.payer
      )

    {:ok, _settled} = Ash.update(intent, %{}, action: :mark_settled, actor: c.payer)
    assert {:error, _} = Assist.get_run(intent.target_id, actor: c.payer)

    applied =
      c.payer
      |> signed_in()
      |> post(~p"/api/payment_intents/#{intent.id}/execute", %{})
      |> json_response(200)

    assert applied["status"] == "applied"
    assert applied["run_id"] == intent.target_id
    assert applied["run_status"] == "paid"
    assert {:ok, %{status: :paid}} = Assist.get_run(intent.target_id, actor: c.payer)
    assert {:ok, %{status: :applied}} = Payments.get_payment_intent(intent.id, actor: c.payer)
  end

  test "a run opens only from the payer's own settled assist payment", c do
    assert {:ok, intent} = Purchase.prepare_jev_assist(c.payer, @args)

    # Not settled yet.
    assert {:error, _} =
             Assist.open_run(%{intent: intent, browser_session_id: nil}, actor: c.payer)

    {:ok, settled} =
      Ash.update(intent, %{}, action: :mark_settled, actor: c.payer)

    # Somebody else's settled payment opens nothing.
    assert {:error, _} =
             Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: c.other)

    assert {:error, _} = Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: nil)

    session = Ecto.UUID.generate()

    assert {:ok, run} =
             Assist.open_run(%{intent: settled, browser_session_id: session}, actor: c.payer)

    assert run.id == intent.target_id
    assert run.payment_intent_id == intent.id
    assert run.payer_profile_id == c.payer.id
    assert run.browser_session_id == session
    assert run.status == :paid
    assert run.sign_in == :unknown
    assert run.goal == @args["goal"]

    # One payment, one run.
    assert {:error, _} =
             Assist.open_run(%{intent: settled, browser_session_id: session}, actor: c.payer)

    # A settled payment of another kind opens nothing either.
    {:ok, tip} =
      Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: c.other}, actor: c.payer)

    {:ok, tip} = Ash.update(tip, %{}, action: :mark_settled, actor: c.payer)
    assert {:error, _} = Assist.open_run(%{intent: tip, browser_session_id: nil}, actor: c.payer)
  end

  test "one assist at a time: a second request while one is open is refused, unpaid, with the first",
       c do
    {:ok, intent} = Purchase.prepare_jev_assist(c.payer, @args)
    {:ok, settled} = Ash.update(intent, %{}, action: :mark_settled, actor: c.payer)
    {:ok, run} = Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: c.payer)

    # Paid and not yet picked up counts as open, as does under way.
    assert {:error, {:assist_running, _run, _url}} = Purchase.prepare_jev_assist(c.payer, @args)
    {:ok, _running} = Assist.start_run(run, authorize?: false)

    refused =
      c.payer
      |> signed_in()
      |> post(~p"/api/payment_intents", %{kind: "jev_assist", args: @args})
      |> json_response(409)

    assert refused["problem_code"] == "assist_running"
    assert refused["run_id"] == run.id
    assert refused["assist_url"] == url(~p"/api/assists/#{run.id}")
    assert refused["error"] =~ "Nothing was charged"

    # Another payer is not held up by it.
    assert {:ok, _theirs} = Purchase.prepare_jev_assist(c.other, @args)
  end

  defp payment(payer, terms) do
    [requirement] = terms["accepts"]

    %{
      "x402Version" => 2,
      "accepted" => requirement,
      "extensions" => terms["extensions"],
      "payload" => %{
        "signature" => "0x" <> String.duplicate("1", 130),
        "authorization" => %{
          "from" => payer.wallet_address,
          "to" => requirement["payTo"],
          "value" => requirement["amount"],
          "validAfter" => "0",
          "validBefore" => Integer.to_string(System.system_time(:second) + 60),
          "nonce" => "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        }
      }
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp signed_in(profile),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), profile.id)

  defp profile(letter),
    do:
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:assist-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate(letter, 40)
      })

  defp server(plug) do
    server =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0},
          id: :assist_payment
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp answer(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

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
