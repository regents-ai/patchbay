defmodule PatchbayWeb.PaymentLimitTest do
  @moduledoc """
  A wallet's share of payment requests, counted by the wallet acted for: the
  hosted wallet tools and a page's new payment intents refuse a wallet whose
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

  test "a page's new payment intent draws on the share of the signed-in wallet", %{conn: conn} do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:limit-" <> Ecto.UUID.generate(),
        wallet_address: address()
      })

    signed_in = fn ->
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{})
      |> put_session(CurrentProfile.session_key(), profile.id)
    end

    create = fn -> signed_in.() |> post("/api/payment_intents", %{"kind" => "nothing"}) end

    refute create.().status == 429
    refute create.().status == 429

    refused = create.()
    assert json_response(refused, 429)["problem_code"] == "rate_limited"
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60

    # Paying an intent already made, reading it back and reading the balance
    # draw on no share, so a signature the wallet gave is never refused for
    # count.
    id = Ecto.UUID.generate()

    refute signed_in.() |> post("/api/payment_intents/#{id}/execute", %{}) |> Map.get(:status) ==
             429

    refute signed_in.() |> get("/api/payment_intents/#{id}") |> Map.get(:status) == 429
    refute signed_in.() |> get("/api/me/regents_balance") |> Map.get(:status) == 429
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
