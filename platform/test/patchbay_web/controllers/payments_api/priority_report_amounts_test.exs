defmodule PatchbayWeb.PaymentsAPI.PriorityReportAmountsTest do
  @moduledoc """
  A person's paid priority report, prepared through the page's own route
  with the person's signed-in session, holds exactly an amount from 1 to
  100 USDC and refuses every other amount and every text that is none.
  The expected bounds are written here, not read from the payments library.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  alias Patchbay.Identity
  alias Patchbay.JevStandIn
  alias PatchbayWeb.Plugs.CurrentProfile

  @min 1_000_000
  @max 100_000_000

  setup do
    original = Application.get_env(:patchbay, :escrow)
    Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("c", 40))
    on_exit(fn -> Application.put_env(:patchbay, :escrow, original) end)
    JevStandIn.accept_posts()
    :ok
  end

  property "a report holds an amount from 1 to 100 USDC and refuses any other", %{conn: conn} do
    check all({written, expected} <- amount(), max_runs: 40) do
      answer = conn |> recycle() |> signed_in(person()) |> prepare(written)

      case expected do
        {:held, shown} ->
          assert %{"amount_usdc" => ^shown} = json_response(answer, 201), written

        :refused ->
          assert %{"error" => %{"code" => "invalid"}} = json_response(answer, 422), written
      end
    end
  end

  # Amounts from 0 to 200 USDC written with 0 to 6 places, cut not rounded,
  # the edges by hand, and text that is no amount.
  defp amount do
    one_of([
      map(tuple({integer(0..200_000_000), integer(0..6)}), fn {atomic, places} ->
        cut = atomic - rem(atomic, Integer.pow(10, 6 - places))
        {written(cut, places), expected(cut)}
      end),
      member_of([
        {"0.999999", :refused},
        {"1", {:held, "1.00"}},
        {"1.00", {:held, "1.00"}},
        {"100", {:held, "100.00"}},
        {"100.00", {:held, "100.00"}},
        {"100.000001", :refused},
        {"0", :refused},
        {"", :refused},
        {"-1.00", :refused},
        {"1e2", :refused},
        {"1.0000001", :refused},
        {"abc", :refused},
        {" 5.00", :refused},
        {"5,00", :refused},
        {"0x10", :refused}
      ])
    ])
  end

  defp expected(atomic) when atomic in @min..@max, do: {:held, shown(atomic)}
  defp expected(_atomic), do: :refused

  # Whole dollars, then at least two places, as an answer writes them.
  defp shown(atomic) do
    places =
      atomic
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")
      |> String.pad_trailing(2, "0")

    "#{div(atomic, 1_000_000)}.#{places}"
  end

  defp written(atomic, 0), do: Integer.to_string(div(atomic, 1_000_000))

  defp written(atomic, places) do
    fraction = atomic |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{div(atomic, 1_000_000)}.#{String.slice(fraction, 0, places)}"
  end

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:amounts-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    })
  end

  defp signed_in(conn, person) do
    conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
  end

  defp prepare(conn, written) do
    post(conn, "/api/payment_intents", %{
      "kind" => "special_post",
      "args" => %{
        "amount_usdc" => written,
        "origin" => "https://shop.example.com/checkout",
        "tool_name" => "add_to_cart",
        "verdict" => "verified_failure",
        "note" => "The tool said it worked but the cart stayed empty."
      }
    })
  end
end
