defmodule PatchbayWeb.CreditsPanelLinkedWalletsTest do
  # Privy makes every person a wallet at sign-in, so a wallet sign-in's account
  # links two wallets: the person's own (the main wallet) and the Privy wallet
  # made beside it. Either pays for Credits; a wallet the account does not link
  # never does. The page chooses from the same list (`data-account-wallets`), as
  # ash-template's panel takes every wallet the account links. Found in the
  # adversarial review of the email sign-in release.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @own "0x" <> String.duplicate("e", 40)
  @made "0x" <> String.duplicate("7", 40)
  @stranger "0x" <> String.duplicate("9", 40)
  @note "#pb-credits-panel .credits-panel__note:not([hidden])"

  setup do
    # Chain reads fail on this machine instead of reaching Base.
    nodes = Application.fetch_env!(:patchbay, :chain_nodes)

    Application.put_env(
      :patchbay,
      :chain_nodes,
      Map.new(nodes, fn {id, _url} -> {id, "http://127.0.0.1:9"} end)
    )

    on_exit(fn -> Application.put_env(:patchbay, :chain_nodes, nodes) end)
    %{person: person()}
  end

  test "the Privy wallet a wallet sign-in links can pay for Credits", %{
    conn: conn,
    person: person
  } do
    view = open_panel(conn, person, @made)
    refute has_element?(view, @note, "linked to this account")
  end

  test "a wallet the account does not link is refused", %{conn: conn, person: person} do
    view = open_panel(conn, person, @stranger)
    assert has_element?(view, @note, "linked to this account")
  end

  test "the page is drawn with every wallet the account links, and its main wallet", %{
    conn: conn,
    person: person
  } do
    html =
      conn
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(person.id)
      |> get(~p"/")
      |> html_response(200)

    assert [account] =
             html |> LazyHTML.from_document() |> LazyHTML.query("#pb-account") |> Enum.to_list()

    assert LazyHTML.attribute(account, "data-account-wallets") == ["#{@own} #{@made}"]
    assert LazyHTML.attribute(account, "data-account-wallet") == [@own]
  end

  defp person do
    did = "did:privy:two-wallets-#{System.unique_integer([:positive])}"

    {:ok, _account} =
      Patchbay.Accounts.establish(%RegentPrivy.Session{
        app_id: "test-app",
        privy_user_id: did,
        session_id: did,
        wallet_address: @own,
        wallet_addresses: [@own, @made]
      })

    Identity.upsert_from_privy!(%{privy_user_id: did, wallet_address: @own})
  end

  defp open_panel(conn, person, active) do
    session = %{"agent_profile_id" => person.id, "signed_in_at" => System.system_time(:second)}
    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.HeaderAccountLive, session: session)

    render_hook(view, "opened", %{})
    assert has_element?(view, "#pb-credits-panel")

    view
    |> with_target("#pb-credits-panel")
    |> render_hook("onchain_active_wallet", %{"address" => active})

    view
  end
end
