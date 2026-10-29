defmodule PatchbayWeb.EnsIdentityTest do
  # A signed-in person is shown under their wallet's ENS picture and name, read
  # from Ethereum by a job each sign-in queues. No test reads the chain: the
  # rows a finished lookup writes are put here directly.
  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Phoenix.LiveViewTest

  alias Patchbay.Accounts
  alias Patchbay.Accounts.EnsIdentity
  alias Patchbay.Identity
  alias PatchbayWeb.Forum.Nameplate
  alias PatchbayWeb.Plugs.CurrentProfile

  @picture "https://metadata.ens.domains/mainnet/avatar/pat.eth"

  test "a sign-in asks for the wallet's ENS name only while the server has an Ethereum endpoint" do
    person = person()

    assert {:ok, account} = Accounts.establish(session(person))
    refute_enqueued(worker: EnsIdentity.Workers.LookUp)
    assert Ash.read!(EnsIdentity) == []

    Application.put_env(:patchbay, :ethereum_read_rpc_url, "https://ethereum.test")
    on_exit(fn -> Application.delete_env(:patchbay, :ethereum_read_rpc_url) end)

    assert {:ok, again} = Accounts.establish(session(person))
    assert again.id == account.id
    assert_enqueued(worker: EnsIdentity.Workers.LookUp, queue: :ens)

    assert [%{lookup_state: :pending, human_account_id: id, wallet_address: wallet}] =
             Ash.read!(EnsIdentity)

    assert {id, wallet} == {account.id, person.wallet_address}
  end

  test "the header shows the ENS picture and the account page the ENS name, only for the wallet they were read for",
       %{conn: conn} do
    person = person()
    {:ok, account} = Accounts.establish(session(person))
    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)

    header = conn |> get(~p"/") |> html_response(200) |> header_picture()
    assert [{"svg", _attrs, _face}] = header

    identity =
      Ash.Seed.seed!(EnsIdentity, %{
        human_account_id: account.id,
        wallet_address: person.wallet_address,
        ens_name: "pat.eth",
        ens_avatar_url: @picture,
        lookup_state: :done
      })

    assert [{"img", attrs, []}] = conn |> get(~p"/") |> html_response(200) |> header_picture()
    assert {"src", @picture} in attrs
    assert {"referrerpolicy", "no-referrer"} in attrs

    {:ok, view, _html} = live(conn, ~p"/account")
    assert view |> element("#account-identity") |> render() =~ "pat.eth"

    Ash.Seed.update!(identity, %{wallet_address: "0x" <> String.duplicate("b", 40)})

    assert [{"svg", _attrs, _face}] =
             conn |> get(~p"/") |> html_response(200) |> header_picture()

    {:ok, view, _html} = live(conn, ~p"/account")
    refute view |> element("#account-identity") |> render() =~ "pat.eth"
  end

  test "a person's posts show their ENS picture and name, and their agent's posts never do" do
    person = person()
    {:ok, account} = Accounts.establish(session(person))

    Ash.Seed.seed!(EnsIdentity, %{
      human_account_id: account.id,
      wallet_address: person.wallet_address,
      ens_name: "pat.eth",
      ens_avatar_url: @picture,
      lookup_state: :done
    })

    author = Identity.get_profile!(person.id)
    PatchbayWeb.SiteEdition.put(:main)

    as_person = render_component(&Nameplate.nameplate/1, author: author, kind: :human, id: "by")
    assert as_person =~ "pat.eth"
    assert [{"img", attrs, []}] = as_person |> Floki.parse_fragment!() |> Floki.find("img")
    assert {"src", @picture} in attrs

    as_agent = render_component(&Nameplate.nameplate/1, author: author, kind: :agent, id: "by")
    assert as_agent =~ author.agent_name
    refute as_agent =~ "pat.eth"
    assert as_agent |> Floki.parse_fragment!() |> Floki.find("img") == []
  end

  defp header_picture(html),
    do: html |> Floki.parse_document!() |> Floki.find(".pb-account-picture")

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:ens-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("a", 40)
    })
  end

  defp session(person) do
    %RegentPrivy.Session{
      app_id: "test-app",
      session_id: "test-session",
      privy_user_id: person.privy_user_id,
      wallet_address: person.wallet_address,
      wallet_addresses: [person.wallet_address]
    }
  end
end
