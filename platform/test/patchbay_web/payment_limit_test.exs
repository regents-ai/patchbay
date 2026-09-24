defmodule PatchbayWeb.PaymentLimitTest do
  @moduledoc """
  A wallet's share of payment requests, counted by the wallet acted for: the
  hosted wallet tools and the payment intent endpoints refuse a wallet whose
  share is spent, however the wallet is spelled, and no other wallet's.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  setup do
    old = Application.fetch_env!(:patchbay, :payments_per_minute)
    Application.put_env(:patchbay, :payments_per_minute, 2)
    on_exit(fn -> Application.put_env(:patchbay, :payments_per_minute, old) end)
    :ok
  end

  test "a hosted wallet tool draws on the share of the wallet it names", %{conn: conn} do
    wallet = address()
    args = %{"payment_intent_id" => Ecto.UUID.generate(), "wallet_address" => wallet}

    assert call(conn, args)["problem_code"] == "not_found"
    assert call(conn, args)["problem_code"] == "not_found"

    refused = call(conn, args)
    assert refused["problem_code"] == "rate_limited"
    assert refused["retry_after_seconds"] in 1..60
    assert refused["error"] =~ "this wallet"

    # The same wallet in other letters is the same share.
    "0x" <> hex = wallet

    assert call(conn, %{args | "wallet_address" => "0x" <> String.upcase(hex)})["problem_code"] ==
             "rate_limited"

    # Another wallet's share is untouched.
    assert call(conn, %{args | "wallet_address" => address()})["problem_code"] == "not_found"
  end

  test "a payment intent endpoint draws on the share of the signed-in wallet", %{conn: conn} do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:limit-" <> Ecto.UUID.generate(),
        wallet_address: address()
      })

    id = Ecto.UUID.generate()

    read = fn ->
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), profile.id)
      |> get("/api/payment_intents/#{id}")
    end

    assert json_response(read.(), 404)["problem_code"] == "not_found"
    assert json_response(read.(), 404)["problem_code"] == "not_found"

    refused = read.()
    assert json_response(refused, 429)["problem_code"] == "rate_limited"
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60

    # The balance read that comes before every paid action is not a payment
    # request: it still answers with the share spent.
    balance =
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), profile.id)
      |> get("/api/me/regents_balance")

    refute balance.status == 429
  end

  defp call(conn, arguments) do
    params = %{"name" => "get_payment_status", "arguments" => arguments}

    %{"result" => %{"structuredContent" => answer}} =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: params})
      )
      |> json_response(200)

    answer
  end

  defp address, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
