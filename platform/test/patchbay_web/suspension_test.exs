defmodule PatchbayWeb.SuspensionTest do
  @moduledoc """
  Acting for a suspended person (Sean, 9 Nov 2026, "100. a"). An app
  connected to them and an agent paired with them are refused while they
  are suspended, by the same check their own web sign-in meets
  (`Patchbay.Identity.AgentProfile.may_act?/1`). Suspending queues a job that
  disconnects their apps, waiting in a paused queue while connected apps are
  switched off, so once it has run reinstating them brings their paired
  agents back and not their apps. Nothing a request carries can suspend or
  reinstate anyone: only Patchbay's console can, and each change is recorded
  with its reason.

  Their own web sign-in is `PatchbayWeb.PrivySessionControllerTest`'s, a
  suspended wallet author `PatchbayWeb.PaymentsAPI.WalletAuthorTest`'s, and
  the console's commands `Patchbay.ReleaseTest`'s.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Boruta.Ecto.Token
  alias Ecto.Adapters.SQL.Sandbox
  alias Patchbay.Identity
  alias Patchbay.Identity.DisconnectApps
  alias PatchbayWeb.SignedAgent

  @console %{role: :system}

  describe "an app connected to a suspended person" do
    setup :connect_apps

    test "is refused, and stays disconnected once they are reinstated", %{
      conn: conn,
      client: client
    } do
      person = person!()
      bearer = connect!(client, person)
      assert watch(conn, bearer).status == 200

      suspended = suspend!(person)
      assert_enqueued(worker: DisconnectApps, args: %{profile_id: person.id})
      assert watch(conn, bearer).status == 401

      assert %{success: 1} = Oban.drain_queue(queue: :connected_apps)

      reinstate!(suspended)
      assert watch(conn, bearer).status == 401
    end

    test "is disconnected by the job once connected apps are switched on, though they were reinstated while apps were off",
         %{conn: conn, client: client} do
      person = person!()
      bearer = connect!(client, person)
      assert watch(conn, bearer).status == 200

      switch_apps(false)
      suspended = suspend!(person)
      assert_enqueued(worker: DisconnectApps, args: %{profile_id: person.id})
      reinstate!(suspended)

      switch_apps(true)
      assert %{success: 1} = Oban.drain_queue(queue: :connected_apps)
      assert watch(conn, bearer).status == 401
    end

    test "is disconnected by one job, however often they are suspended and reinstated while it waits",
         %{conn: conn, client: client} do
      person = person!()
      bearer = connect!(client, person)

      switch_apps(false)
      again = person |> suspend!() |> reinstate!() |> suspend!("Spam again")
      assert [_one] = all_enqueued(worker: DisconnectApps, args: %{profile_id: person.id})

      switch_apps(true)
      assert %{success: 1} = Oban.drain_queue(queue: :connected_apps)

      reinstate!(again)
      assert watch(conn, bearer).status == 401
    end

    test "stays disconnected when the job runs twice", %{conn: conn, client: client} do
      person = person!()
      bearer = connect!(client, person)
      suspended = suspend!(person)

      assert :ok = perform_job(DisconnectApps, %{profile_id: person.id})
      assert :ok = perform_job(DisconnectApps, %{profile_id: person.id})

      reinstate!(suspended)
      assert watch(conn, bearer).status == 401
    end
  end

  describe "the job's queue" do
    test "starts paused at a boot with connected apps switched off, and running at a boot with them on" do
      for {setting, paused?} <- [{nil, true}, {"true", false}] do
        name = {:boot, setting}

        start_supervised!(
          {Oban,
           setting
           |> booted_oban()
           |> Keyword.merge(name: name, testing: :disabled, plugins: false, peer: false)
           |> Keyword.update!(:queues, &Keyword.take(&1, [:connected_apps]))},
          id: name
        )

        assert %{paused: ^paused?} = Oban.check_queue(name, queue: :connected_apps)
      end
    end
  end

  describe "an agent paired with a suspended person" do
    setup do
      SignedAgent.stub_siwa()
    end

    test "is refused, and acts again once they are reinstated", %{conn: conn} do
      agent = SignedAgent.pair!()
      assert conn |> follows(agent) |> json_response(200)

      suspended = suspend!(agent.owner)

      assert %{"error" => %{"code" => "agent_unavailable"}} =
               conn |> follows(agent) |> json_response(401)

      reinstate!(suspended)
      assert conn |> follows(agent) |> json_response(200)
    end

    test "is refused while its own profile is suspended", %{conn: conn} do
      agent = SignedAgent.pair!()
      assert conn |> follows(agent) |> json_response(200)

      suspend!(Identity.get_wallet_profile!(8453, agent.wallet))

      assert %{"error" => %{"code" => "agent_unavailable"}} =
               conn |> follows(agent) |> json_response(401)
    end
  end

  describe "suspending and reinstating" do
    test "answer only Patchbay's console, whoever else asks, and change nothing for them" do
      person = person!()

      senders = [
        nil,
        person,
        person!(),
        Patchbay.AssistFixtures.paired_agent(),
        Identity.upsert_from_wallet!(%{wallet_address: wallet()})
      ]

      for actor <- senders do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Identity.suspend_profile(person, "Spam", actor: actor)
      end

      assert Identity.get_profile!(person.id).status == :active
      assert Identity.status_changes!(person.id, actor: @console) == []
      refute_enqueued(worker: DisconnectApps)

      assert {:ok, suspended} = Identity.suspend_profile(person, "Spam", actor: @console)

      for actor <- senders do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Identity.reinstate_profile(suspended, "Appeal upheld", actor: actor)
      end

      assert Identity.get_profile!(person.id).status == :suspended
      assert [%{action: :suspend}] = Identity.status_changes!(person.id, actor: @console)

      assert {:ok, %{status: :active}} =
               Identity.reinstate_profile(suspended, "Appeal upheld", actor: @console)
    end

    test "each leave a record with their reason, which only the console reads" do
      person = person!()

      person |> suspend!("Spam") |> reinstate!("Appeal upheld")
      person.id |> Identity.get_profile!() |> suspend!("Spam again")

      assert [
               %{action: :suspend, reason: "Spam"},
               %{action: :reinstate, reason: "Appeal upheld"},
               %{action: :suspend, reason: "Spam again"}
             ] = Identity.status_changes!(person.id, actor: @console)

      for actor <- [nil, person, person!()] do
        refute match?({:ok, [_ | _]}, Identity.status_changes(person.id, actor: actor))
      end
    end

    test "an already suspended profile is not suspended again" do
      suspended = suspend!(person!())

      assert {:error, %Ash.Error.Invalid{}} =
               Identity.suspend_profile(suspended, "Spam", actor: @console)

      assert [_one] = Identity.status_changes!(suspended.id, actor: @console)
    end
  end

  defp suspend!(profile, reason \\ "Spam"),
    do: Identity.suspend_profile!(profile, reason, actor: @console)

  defp reinstate!(profile, reason \\ "Appeal upheld"),
    do: Identity.reinstate_profile!(profile, reason, actor: @console)

  # Oban's settings as a boot reads them with PATCHBAY_OAUTH_ENABLED set to
  # `setting`, or unset: config/runtime.exs over the compiled ones.
  defp booted_oban(setting) do
    previous = System.get_env("PATCHBAY_OAUTH_ENABLED")
    put_system_env("PATCHBAY_OAUTH_ENABLED", setting)

    try do
      runtime = Config.Reader.read!("config/runtime.exs", env: :test, imports: :disabled)

      [patchbay: [{Oban, Application.fetch_env!(:patchbay, Oban)}]]
      |> Config.Reader.merge(runtime)
      |> get_in([:patchbay, Oban])
    after
      put_system_env("PATCHBAY_OAUTH_ENABLED", previous)
    end
  end

  defp put_system_env(name, nil), do: System.delete_env(name)
  defp put_system_env(name, value), do: System.put_env(name, value)

  defp switch_apps(on?) do
    Application.put_env(
      :patchbay,
      Patchbay.OAuth,
      Keyword.put(Application.fetch_env!(:patchbay, Patchbay.OAuth), :enabled?, on?)
    )
  end

  # Connected apps switched on, with ChatGPT registered as an app.
  defp connect_apps(_context) do
    put_env(
      :patchbay,
      Patchbay.OAuth,
      Keyword.put(Application.fetch_env!(:patchbay, Patchbay.OAuth), :enabled?, true)
    )

    put_env(
      :regent_oauth,
      RegentOAuth.Repo,
      Keyword.put(Application.fetch_env!(:regent_oauth, RegentOAuth.Repo), :pool, Sandbox)
    )

    start_supervised!(RegentOAuth.Repo)
    :ok = Sandbox.checkout(RegentOAuth.Repo)
    Sandbox.mode(RegentOAuth.Repo, {:shared, self()})

    {:ok, client} =
      Boruta.Ecto.Admin.Clients.create_client(%{
        name: "ChatGPT",
        redirect_uris: ["https://chatgpt.com/connector/oauth/callback"],
        confidential: false,
        pkce: true,
        supported_grant_types: ["authorization_code", "refresh_token", "revoke"],
        access_token_ttl: 3600,
        authorization_code_ttl: 60,
        refresh_token_ttl: 2_592_000
      })

    %{client: client}
  end

  # A live access token the person granted `client`, as the provider keeps it:
  # only its hash.
  defp connect!(client, person) do
    bearer = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token =
      RegentOAuth.Repo.insert!(%Token{
        type: "access_token",
        value: RegentOAuth.hash_token(bearer),
        client_id: client.id,
        sub: person.privy_user_id,
        scope: RegentOAuth.scope(),
        expires_at: System.system_time(:second) + 3600
      })

    :ok = RegentOAuth.bind(token.id)
    bearer
  end

  # The app asks to stop watching updates it never asked for: its token is
  # checked first, and refused with 401, before the request is read.
  defp watch(conn, bearer) do
    conn
    |> recycle()
    |> on_open()
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/chatgpt/mcp",
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "events/unsubscribe", params: %{}})
    )
  end

  defp follows(conn, agent), do: conn |> SignedAgent.sign(agent) |> get("/forum/subscriptions")

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:suspension-#{System.unique_integer([:positive])}",
      wallet_address: wallet()
    })
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp put_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> Application.put_env(app, key, old) end)
  end
end
