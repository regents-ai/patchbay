defmodule PatchbayWeb.CreditsTest do
  @moduledoc """
  Buying Patchbay Credits by card, end to end through the web: the owner's
  profile offers the bundles, a bundle opens Stripe Checkout at the price set
  here for the signed-in profile, Stripe's signed event credits the buyer, and
  only the owner ever sees the balance or what they have paid and bought.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.Plugs.CurrentProfile

  @secret "whsec_test_credits"

  setup do
    previous = Application.get_env(:patchbay, :stripe)
    previous_req = Application.get_env(:patchbay, :stripe_req_options)

    Application.put_env(:patchbay, :stripe,
      secret_key: "sk_test_credits",
      webhook_secret: @secret
    )

    on_exit(fn ->
      restore(:stripe, previous)
      restore(:stripe_req_options, previous_req)
    end)

    %{buyer: profile("buyer")}
  end

  describe "the owner's credits on their profile" do
    test "the owner sees the balance, the bundles and the history; nobody else does", %{
      conn: conn,
      buyer: buyer
    } do
      {:ok, :credited} =
        Credits.record_card_purchase(buyer.id, 500, "pi_" <> Ecto.UUID.generate())

      mine = conn |> signed_in(buyer) |> get(~p"/agents/#{buyer.public_id}") |> html_response(200)
      assert mine =~ ~s(id="patchbay-credits")
      assert mine =~ "Balance: 5.00 credits"
      assert mine =~ "Buy 20 credits for $20"
      assert mine =~ "Credits bought by card"
      assert mine =~ "+5.00 credits"

      theirs =
        build_conn()
        |> signed_in(profile("other"))
        |> get(~p"/agents/#{buyer.public_id}")
        |> html_response(200)

      refute theirs =~ "patchbay-credits"
      refute theirs =~ "credits"

      markdown =
        build_conn()
        |> signed_in(buyer)
        |> put_req_header("accept", "text/markdown")
        |> get(~p"/agents/#{buyer.public_id}")
        |> response(200)

      refute markdown =~ "credits"
    end

    test "no bundles are offered when card payments are not set up", %{conn: conn, buyer: buyer} do
      Application.delete_env(:patchbay, :stripe)

      mine = conn |> signed_in(buyer) |> get(~p"/agents/#{buyer.public_id}") |> html_response(200)
      assert mine =~ "Balance: 0.00 credits"
      refute mine =~ "Buy 2 credits"
    end

    test "coming back from Stripe says what happened", %{conn: conn, buyer: buyer} do
      page =
        conn
        |> signed_in(buyer)
        |> get(~p"/agents/#{buyer.public_id}?credits=bought")
        |> html_response(200)

      assert page =~ "Your credits show here as soon as Stripe confirms the payment"
    end
  end

  describe "opening Stripe Checkout" do
    test "a bundle opens Checkout at its own price, for the signed-in profile", %{
      conn: conn,
      buyer: buyer
    } do
      stripe_answers(200, %{"url" => "https://checkout.stripe.com/c/pay/cs_test_1"})

      conn = conn |> signed_in(buyer) |> post(~p"/credits/checkout", %{"bundle" => "10"})

      assert redirected_to(conn, 302) == "https://checkout.stripe.com/c/pay/cs_test_1"
      assert_received {:stripe, form, authorization, version}
      assert authorization == "Bearer sk_test_credits"
      assert version == "2026-08-26.dahlia"
      assert form["line_items[0][price_data][unit_amount]"] == "1000"
      assert form["line_items[0][price_data][currency]"] == "usd"
      assert form["metadata[patchbay_profile_id]"] == buyer.id
      assert form["payment_intent_data[metadata][patchbay_profile_id]"] == buyer.id
      assert form["success_url"] =~ "/agents/#{buyer.public_id}?credits=bought"
    end

    test "a bundle that is not on sale is not opened", %{conn: conn, buyer: buyer} do
      stripe_answers(200, %{"url" => "https://checkout.stripe.com/c/pay/cs_test_2"})

      assert_error_sent 404, fn ->
        conn |> signed_in(buyer) |> post(~p"/credits/checkout", %{"bundle" => "7"})
      end

      refute_received {:stripe, _form, _authorization, _version}
    end

    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      conn = post(conn, ~p"/credits/checkout", %{"bundle" => "5"})
      assert redirected_to(conn, 302) == ~p"/profile"
    end

    test "when Stripe does not answer, the owner is told nothing was charged", %{
      conn: conn,
      buyer: buyer
    } do
      stripe_answers(500, %{"error" => %{"message" => "down"}})

      conn = conn |> signed_in(buyer) |> post(~p"/credits/checkout", %{"bundle" => "5"})

      assert redirected_to(conn, 302) =~ "/agents/#{buyer.public_id}?credits=unopened"
    end

    test "nothing is sold when card payments are not set up", %{conn: conn, buyer: buyer} do
      Application.delete_env(:patchbay, :stripe)

      assert_error_sent 404, fn ->
        conn |> signed_in(buyer) |> post(~p"/credits/checkout", %{"bundle" => "5"})
      end
    end
  end

  describe "Stripe's webhook" do
    test "a paid bundle credits its buyer once, however often Stripe sends it", %{buyer: buyer} do
      event = checkout_completed(buyer.id, 2_000, "pi_" <> Ecto.UUID.generate())

      assert %{"received" => true} = event |> webhook() |> json_response(200)
      assert %{"received" => true} = event |> webhook() |> json_response(200)

      assert Credits.balance_atomic(buyer.id) == 20_000_000
    end

    test "a refund and a dispute take the credits back", %{buyer: buyer} do
      payment = "pi_" <> Ecto.UUID.generate()
      checkout_completed(buyer.id, 1_000, payment) |> webhook() |> json_response(200)

      buyer.id |> refunded(payment, 200) |> webhook() |> json_response(200)

      %{
        "type" => "charge.dispute.created",
        "data" => %{"object" => %{"id" => "du_web", "payment_intent" => payment, "amount" => 800}}
      }
      |> webhook()
      |> json_response(200)

      assert Credits.balance_atomic(buyer.id) == 0
    end

    test "a refund that comes before its bundle's purchase is sent again until it lands", %{
      buyer: buyer
    } do
      payment = "pi_" <> Ecto.UUID.generate()
      refund = refunded(buyer.id, payment, 400)

      assert %{"error" => "not_recorded"} = refund |> webhook() |> json_response(500)

      checkout_completed(buyer.id, 1_000, payment) |> webhook() |> json_response(200)
      assert %{"received" => true} = refund |> webhook() |> json_response(200)

      assert Credits.balance_atomic(buyer.id) == 6_000_000
    end

    test "an event Stripe did not sign, or signed too long ago, writes nothing", %{buyer: buyer} do
      event = checkout_completed(buyer.id, 500, "pi_" <> Ecto.UUID.generate())
      body = Jason.encode!(event)
      now = System.system_time(:second)

      assert %{"error" => "unsigned"} =
               body
               |> post_webhook("t=#{now},v1=#{String.duplicate("0", 64)}")
               |> json_response(400)

      stale = now - 301

      assert %{"error" => "unsigned"} =
               body
               |> post_webhook("t=#{stale},v1=#{Patchbay.Stripe.sign("#{stale}.#{body}")}")
               |> json_response(400)

      assert %{"error" => "unsigned"} = body |> post_webhook(nil) |> json_response(400)

      assert Credits.balance_atomic(buyer.id) == 0
    end

    test "a card payment that is not a bundle is answered and left alone" do
      assert %{"received" => true} =
               %{
                 "type" => "checkout.session.completed",
                 "data" => %{
                   "object" => %{
                     "metadata" => %{},
                     "payment_status" => "paid",
                     "amount_total" => 900,
                     "payment_intent" => "pi_other"
                   }
                 }
               }
               |> webhook()
               |> json_response(200)

      assert %{"received" => true} =
               %{
                 "type" => "charge.refunded",
                 "data" => %{
                   "object" => %{
                     "metadata" => %{},
                     "payment_intent" => "pi_other",
                     "amount_refunded" => 900
                   }
                 }
               }
               |> webhook()
               |> json_response(200)
    end

    test "there is no webhook when card payments are not set up", %{buyer: buyer} do
      event = checkout_completed(buyer.id, 500, "pi_" <> Ecto.UUID.generate())
      body = Jason.encode!(event)
      now = System.system_time(:second)
      signature = "t=#{now},v1=#{Patchbay.Stripe.sign("#{now}.#{body}")}"
      Application.delete_env(:patchbay, :stripe)

      assert_error_sent 404, fn -> post_webhook(body, signature) end
    end
  end

  defp checkout_completed(profile_id, cents, payment) do
    %{
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "metadata" => %{"patchbay_profile_id" => profile_id},
          "payment_status" => "paid",
          "amount_total" => cents,
          "payment_intent" => payment
        }
      }
    }
  end

  defp refunded(profile_id, payment, cents) do
    %{
      "type" => "charge.refunded",
      "data" => %{
        "object" => %{
          "metadata" => %{"patchbay_profile_id" => profile_id},
          "payment_intent" => payment,
          "amount_refunded" => cents
        }
      }
    }
  end

  defp webhook(event) do
    body = Jason.encode!(event)
    now = System.system_time(:second)
    post_webhook(body, "t=#{now},v1=#{Patchbay.Stripe.sign("#{now}.#{body}")}")
  end

  defp post_webhook(body, signature) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    conn = if signature, do: put_req_header(conn, "stripe-signature", signature), else: conn
    post(conn, "/webhooks/stripe", body)
  end

  defp stripe_answers(status, answer) do
    test = self()

    Application.put_env(:patchbay, :stripe_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test,
          {:stripe, URI.decode_query(body),
           conn |> Plug.Conn.get_req_header("authorization") |> List.first(),
           conn |> Plug.Conn.get_req_header("stripe-version") |> List.first()}
        )

        conn |> Plug.Conn.put_status(status) |> Req.Test.json(answer)
      end
    )
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:#{subject}-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("e", 40)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end

  defp restore(setting, nil), do: Application.delete_env(:patchbay, setting)
  defp restore(setting, value), do: Application.put_env(:patchbay, setting, value)
end
