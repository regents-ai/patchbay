defmodule Patchbay.Points.SignInMilestonesTest do
  # Invariant: a new account and a person's paired agents each earn their
  # one-time award once, in one entry. The offer is made inside the save that
  # earns it, so a save that rolls back offers nothing, and a sign-in to an
  # account that already exists offers nothing more. As ash-template's
  # sign_in_milestones_test.exs.
  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  require Ash.Query
  alias Patchbay.{Accounts, Repo}
  alias RegentPoints.{Entry, Event, IntakeWorker, Store, Worker}

  @rules ["account.activated", "agent.activated"]
  @system %{role: :system}

  setup do
    config = Application.get_all_env(:regent_points)
    Application.put_env(:regent_points, :starts_at, ~U[2020-01-01 00:00:00Z])
    Application.put_env(:regent_points, :approved_rules, @rules)

    on_exit(fn ->
      Enum.each(config, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)
  end

  test "a new account earns its activation once, and signing in again offers nothing" do
    did = "did:privy:activated-" <> Ecto.UUID.generate()
    wallet = wallet()
    attrs = %{privy_user_id: did, wallet_address: wallet, wallet_addresses: [wallet]}

    Repo.transaction(fn ->
      Accounts.register_verified!(attrs, actor: @system, return_notifications?: true)
      Repo.rollback(:undone)
    end)

    assert offers("account.activated") == []

    account = Accounts.register_verified!(attrs, actor: @system)
    assert Accounts.register_verified!(attrs, actor: @system).id == account.id

    assert [offer] = offers("account.activated")
    assert offer.args["source_event_key"] == to_string(account.id)

    # The account's time is kept to the second, rounded, so it can be up to
    # half a second ahead; Points' check waits for it.
    Process.sleep(1_000)
    award("account.activated", account.id)
    assert [25_000_000] = points(account.id, "account.activated")
  end

  test "signing in to an account that already exists still saves its wallets" do
    did = "did:privy:returning-" <> Ecto.UUID.generate()
    first = wallet()
    second = wallet()

    session = fn wallets ->
      %RegentPrivy.Session{
        app_id: "test-app",
        session_id: "test-session",
        privy_user_id: did,
        wallet_address: hd(wallets),
        wallet_addresses: wallets,
        issued_at: :erlang.system_time(:second),
        expires_at: :erlang.system_time(:second) + 3600
      }
    end

    assert {:ok, account} = Accounts.establish(session.([first]))
    assert {:ok, again} = Accounts.establish(session.([second, first]))
    assert again.id == account.id
    assert %{wallet_address: ^second, wallet_addresses: [^second, ^first]} = again
    assert [_offer] = offers("account.activated")
  end

  test "a person's paired agents earn the first-agent award once" do
    did = "did:privy:paired-" <> Ecto.UUID.generate()
    wallet = wallet()

    account =
      Accounts.register_verified!(
        %{privy_user_id: did, wallet_address: wallet, wallet_addresses: [wallet]},
        actor: @system
      )

    agents =
      for name <- ["First", "Second"] do
        code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: did})

        RegentAgents.pair_agent!(code.code, name, :codex,
          actor: %RegentAgents.Agent{wallet: wallet()}
        )
      end

    assert length(offers("agent.activated")) == 2

    award("agent.activated", account.id)
    assert [25_000_000] = points(account.id, "agent.activated")

    # The award's agent is a paired wallet, and the Points page names it.
    assert [%{actor_id: wallet}] =
             Ash.Query.filter(Entry, account_id == ^account.id and rule_id == "agent.activated")
             |> Ash.read!(actor: Store.system())

    assert %{name: name} = Enum.find(agents, &(&1.wallet == wallet))
    assert {:ok, %{^wallet => ^name}} = Patchbay.Points.Accounts.agent_names(account.id, [wallet])
  end

  defp offers(rule), do: all_enqueued(worker: IntakeWorker, args: %{"rule_id" => rule})

  # Points' check of every offer for the rule, then its award for the account.
  defp award(rule, account_id) do
    for job <- offers(rule), do: assert(:ok = perform_job(IntakeWorker, job.args))

    events =
      Ash.read!(Ash.Query.filter(Event, account_id == ^account_id), actor: Store.system())
      |> Enum.map(& &1.id)

    for job <- all_enqueued(worker: Worker),
        job.args["event_id"] in events,
        do: assert(:ok = perform_job(Worker, job.args))
  end

  defp points(account_id, rule) do
    Ash.Query.filter(Entry, account_id == ^account_id and rule_id == ^rule)
    |> Ash.read!(actor: Store.system())
    |> Enum.map(& &1.points_micro_delta)
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
