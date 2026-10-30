defmodule PatchbayWeb.PairingBoxTest do
  @moduledoc """
  Pair New Agent on the Agents page: each agent keeps its own code until it
  expires or a new one is asked for, and the form arriving with no agent chosen,
  as a reconnecting page sends it, changes nothing.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  test "Pair New Agent sent with no agent chosen changes nothing", %{conn: conn} do
    view = conn |> signed_in("did:privy:pair-empty", "e") |> agents_page()
    box = element(view, "#account-pairing-box")

    render_change(box, %{"_target" => ["harness"]})
    render_submit(box, %{})

    assert has_element?(view, "#account-pairing-box input[name=harness]")
    refute has_element?(view, "#account-pairing-box input[name=harness][checked]")
  end

  test "each agent keeps its code, and only a new code replaces the chosen one", %{conn: conn} do
    box =
      conn
      |> signed_in("did:privy:pair-keep", "f")
      |> agents_page()
      |> element("#account-pairing-box")

    code_for = fn harness -> box |> render_change(%{"harness" => harness}) |> code() end

    codex = code_for.("codex")
    hermes = code_for.("hermes")

    assert codex != hermes
    assert code_for.("codex") == codex

    renewed = box |> render_submit(%{"harness" => "codex"}) |> code()

    assert renewed != codex
    assert code_for.("hermes") == hermes
    assert code_for.("codex") == renewed
  end

  defp signed_in(conn, privy_user_id, hex) do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: privy_user_id,
        wallet_address: "0x" <> String.duplicate(hex, 40)
      })

    conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
  end

  defp agents_page(conn) do
    {:ok, view, _html} = live(conn, ~p"/account/agents")
    view
  end

  # The message shown in the box, which holds its code.
  defp code(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#account-pairing-box pre")
      |> LazyHTML.text()
end
