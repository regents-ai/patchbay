defmodule PatchbayWeb.PaymentLimitTest do
  @moduledoc """
  A wallet's share of payment requests, counted by the wallet acted for: a
  page's new payment intents refuse a wallet whose share is spent.
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
      |> CurrentProfile.sign_in(profile.id)
    end

    create = fn -> signed_in.() |> post("/api/payment_intents", %{"kind" => "nothing"}) end

    refute create.().status == 429
    refute create.().status == 429

    refused = create.()
    assert json_response(refused, 429)["error"]["code"] == "rate_limited"
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60

    # Paying an intent already made, reading it back and reading the balance
    # draw on no share, so a signature the wallet gave is never refused for
    # count.
    id = Ecto.UUID.generate()

    refute signed_in.() |> post("/api/payment_intents/#{id}/execute", %{}) |> Map.get(:status) ==
             429

    refute signed_in.() |> get("/api/payment_intents/#{id}") |> Map.get(:status) == 429
    refute signed_in.() |> get("/api/me/usdc_balance") |> Map.get(:status) == 429
  end

  defp address, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
