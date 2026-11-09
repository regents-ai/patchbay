defmodule PatchbayWeb.EnsIdentityTest do
  # A signed-in person is shown under their wallet's ENS picture and name, read
  # from Ethereum by a job each sign-in queues. No test reads the chain: either
  # the rows a finished lookup writes are put here directly, or the lookup
  # answers from `PatchbayWeb.EnsStandIn`.
  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Phoenix.LiveViewTest

  alias Patchbay.Accounts
  alias Patchbay.Accounts.EnsIdentity
  alias Patchbay.Identity
  alias PatchbayWeb.EnsStandIn
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

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(person.id, System.os_time(:second))

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

    # At the open address the ENS name is not theirs to go by, nor its picture.
    PatchbayWeb.SiteEdition.put(:open)
    at_open = render_component(&Nameplate.nameplate/1, author: author, kind: :human, id: "by")
    refute at_open =~ "pat.eth"
    assert at_open |> Floki.parse_fragment!() |> Floki.find("img") == []
  end

  test "a new wallet shows no name while its lookup runs, then its own name" do
    {account, wallet_b} = moved_to_new_wallet({:ok, %{name: "b.eth", avatar_url: nil}})

    assert %{lookup_state: :pending} = identity()
    assert ens_name(account) == nil

    Oban.drain_queue(queue: :ens)
    assert %{lookup_state: :done, wallet_address: ^wallet_b} = identity()
    assert ens_name(account) == "b.eth"
  end

  test "a new wallet whose lookup fails shows no name, never the old wallet's" do
    {account, _wallet_b} = moved_to_new_wallet({:error, :unreachable})

    for _attempt <- 1..3, do: Oban.drain_queue(queue: :ens, with_scheduled: true)

    assert %{lookup_state: :failed, ens_name: "a.eth"} = identity()
    assert ens_name(account) == nil
  end

  # An account whose wallet A was looked up as "a.eth" signs in with wallet B,
  # whose lookup will answer `answer_b`.
  defp moved_to_new_wallet(answer_b) do
    Application.put_env(:patchbay, :ethereum_read_rpc_url, "https://ethereum.test")
    on_exit(fn -> Application.delete_env(:patchbay, :ethereum_read_rpc_url) end)

    person = person()
    wallet_b = "0x" <> String.duplicate("b", 40)
    EnsStandIn.answer(person.wallet_address, {:ok, %{name: "a.eth", avatar_url: nil}})
    EnsStandIn.answer(wallet_b, answer_b)

    {:ok, account} = Accounts.establish(session(person))
    Oban.drain_queue(queue: :ens)
    assert ens_name(account) == "a.eth"

    moved = %{session(person) | wallet_address: wallet_b, wallet_addresses: [wallet_b]}
    {:ok, account} = Accounts.establish(moved)
    {account, wallet_b}
  end

  defp identity, do: Ash.read_one!(EnsIdentity)

  # The name the account is shown under.
  defp ens_name(account), do: Ash.load!(account, :ens_name, authorize?: false).ens_name

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
