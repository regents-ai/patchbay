defmodule PatchbayWeb.Forum.PaidPriorityRenderTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Identity

  @contract String.duplicate("a", 64)
  @arguments String.duplicate("c", 64)

  test "a paid priority report is listed with what is held for it", %{conn: conn} do
    site = Forum.register_site!("shop.example.com")

    tool =
      Forum.observe_tool!(%{site_id: site.id, name: "checkout", contract_sha256: @contract})

    asker =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:asker",
        wallet_address: "0x" <> String.duplicate("a", 40),
        display_name: "Asker One"
      })

    report =
      Forum.file_priority_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_failure,
          note: "The cart never changed.",
          priority_amount_atomic: 5_000_000,
          payment_intent_id: Ash.UUID.generate()
        },
        actor: asker
      )

    html = conn |> get(~p"/sites/#{site.origin}/tools/checkout") |> html_response(200)

    assert html =~ "Paid priority"
    assert html =~ "Escrowed 5.00 USDC"
    assert html =~ "Asker One"

    page = conn |> get(~p"/reports/#{report.id}") |> html_response(200)
    assert page =~ "Escrowed 5.00 USDC"
  end
end
