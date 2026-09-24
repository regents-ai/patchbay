defmodule PatchbayWeb.CreditsForWalletTest do
  @moduledoc """
  Credits bought for a wallet by anyone, by card or Link: the payment page
  names the wallet and the credits, opening it adds nothing, a page left
  unpaid adds nothing, and only Stripe's signed word that the payment was
  taken adds the credits, once however often Stripe sends it, to the balance
  the wallet spends when the payment lands.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits

  setup do
    previous = Application.get_env(:patchbay, :stripe)
    previous_req = Application.get_env(:patchbay, :stripe_req_options)

    Application.put_env(:patchbay, :stripe,
      secret_key: "sk_test_wallet_credits",
      webhook_secret: "whsec_test_wallet_credits"
    )

    stripe_answers(%{"url" => "https://checkout.stripe.com/c/pay/cs_test_wallet"})

    on_exit(fn ->
      Application.put_env(:patchbay, :stripe, previous)
      Application.put_env(:patchbay, :stripe_req_options, previous_req)
    end)
  end

  test "credits bought for a wallet arrive once, only when Stripe says the payment was taken",
       %{conn: conn} do
    wallet = "0x" <> String.duplicate("c", 40)

    opened =
      conn
      |> post(~p"/api/credits/checkout", %{"wallet_address" => wallet, "bundle_dollars" => 10})
      |> json_response(201)

    agent = Identity.upsert_from_wallet!(%{wallet_address: wallet})

    assert %{
             "checkout_url" => "https://checkout.stripe.com/c/pay/cs_test_wallet",
             "credits" => "10.00",
             "recipient" => %{"wallet_address" => ^wallet, "shares_with" => nil}
           } = opened

    # The page names the wallet for whoever pays, and the payment carries it.
    assert_received {:stripe, form}

    assert form["line_items[0][price_data][product_data][name]"] =~
             "10 Patchbay Credits for wallet 0xcccc"

    assert form["line_items[0][price_data][product_data][description]"] =~ wallet
    assert form["payment_intent_data[metadata][patchbay_profile_id]"] == agent.id
    assert form["success_url"] =~ "/agents/#{agent.public_id}?credits=bought"

    # Open, abandoned, or finished without a payment taken: nothing.
    assert Credits.balance_atomic(agent.id) == 0
    assert webhook(session("checkout.session.expired", agent.id, "unpaid")).status == 200
    assert webhook(session("checkout.session.completed", agent.id, "unpaid")).status == 200
    assert Credits.balance_atomic(agent.id) == 0

    # Paid, and sent again: credited once.
    paid = session("checkout.session.completed", agent.id, "paid")
    assert webhook(paid).status == 200
    assert webhook(paid).status == 200
    assert Credits.balance_atomic(agent.id) == 10_000_000

    # Paired with a person, the wallet shares their balance, and credits
    # bought for it through the hosted tool land there.
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:wallet-credits-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("d", 40)
      })

    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)

    %{"structuredContent" => bought} =
      mcp(conn, "buy_credits", %{"wallet_address" => wallet, "bundle_dollars" => 5})

    assert bought["recipient"]["shares_with"]["profile_id"] == person.public_id
    assert_received {:stripe, form}

    assert form["line_items[0][price_data][product_data][description]"] =~
             "shares with the person"

    assert webhook(session("checkout.session.completed", agent.id, "paid", 500)).status == 200
    assert Credits.balance_atomic(person.id) == 15_000_000

    # Whoever paid comes back to the wallet's page and is told where the
    # credits went, never the balance.
    page = conn |> get(~p"/agents/#{agent.public_id}?credits=bought") |> html_response(200)
    assert page =~ "added to the Patchbay Credits of wallet #{wallet}"
    assert page =~ "which it shares with #{person.human_name}"
    refute page =~ "Balance:"
  end

  defp session(type, profile_id, payment_status, cents \\ 1_000) do
    # One Checkout page is one payment intent; a second bundle is a second.
    %{
      "type" => type,
      "data" => %{
        "object" => %{
          "metadata" => %{"patchbay_profile_id" => profile_id},
          "payment_status" => payment_status,
          "amount_total" => cents,
          "payment_intent" => "pi_wallet_#{profile_id}_#{cents}"
        }
      }
    }
  end

  defp webhook(event) do
    body = Jason.encode!(event)
    now = System.system_time(:second)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{now},v1=#{Patchbay.Stripe.sign("#{now}.#{body}")}")
    |> post("/webhooks/stripe", body)
  end

  defp mcp(conn, name, arguments) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{"name" => name, "arguments" => arguments}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp stripe_answers(answer) do
    test = self()

    Application.put_env(:patchbay, :stripe_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:stripe, URI.decode_query(body)})
        Req.Test.json(conn, answer)
      end
    )
  end
end
