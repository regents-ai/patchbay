defmodule Patchbay.Points.StartAwardsTest do
  # Invariant: an account and its paired agent from before the Points start earn
  # their one-time awards at the start, once, through this site's own checks,
  # without the person doing anything. As ash-template's start_awards_test.exs.
  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  require Ash.Query
  alias Patchbay.Accounts
  alias RegentPoints.{Entry, Event, IntakeWorker, StartAwards, Store, Worker}

  @rules ["account.activated", "agent.activated"]

  setup do
    config = Application.get_all_env(:regent_points)

    on_exit(fn ->
      Enum.each(config, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)

    # Before launch nothing is approved: what people do then earns nothing.
    Application.put_env(:regent_points, :starts_at, nil)
    Application.put_env(:regent_points, :approved_rules, [])
  end

  test "what an account had before the start earns once, at the start" do
    did = "did:privy:before-start-" <> Ecto.UUID.generate()
    wallet = wallet()

    assert {:ok, account} =
             Accounts.establish(%RegentPrivy.Session{
               app_id: "test-app",
               session_id: "test-session",
               privy_user_id: did,
               wallet_address: wallet,
               wallet_addresses: [wallet],
               issued_at: :erlang.system_time(:second),
               expires_at: :erlang.system_time(:second) + 3600
             })

    code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: did})

    RegentAgents.pair_agent!(code.code, "Early", :codex,
      actor: %RegentAgents.Agent{wallet: wallet()}
    )

    # Their offers are turned down while nothing is approved.
    before = Enum.flat_map(@rules, &offers/1)
    for job <- before, do: assert(:ok = perform_job(IntakeWorker, job.args))
    assert points(account.id) == []

    # The account's time is kept to the second, rounded, so it can be up to half
    # a second ahead of the clock.
    Process.sleep(1_000)
    start = DateTime.utc_now()
    Application.put_env(:regent_points, :starts_at, start)
    Application.put_env(:regent_points, :approved_rules, @rules)

    assert :ok = StartAwards.perform(%Oban.Job{})
    at_start = Enum.flat_map(@rules, &offers/1) -- before
    for job <- at_start, do: assert(:ok = perform_job(IntakeWorker, job.args))

    events =
      Ash.read!(Ash.Query.filter(Event, account_id == ^account.id), actor: Store.system())
      |> Enum.map(& &1.id)

    for job <- all_enqueued(worker: Worker),
        job.args["event_id"] in events,
        do: assert(:ok = perform_job(Worker, job.args))

    assert [
             %{rule_id: "account.activated", points_micro_delta: 25_000_000, earned_at: one},
             %{rule_id: "agent.activated", points_micro_delta: 25_000_000, earned_at: two}
           ] = points(account.id)

    assert DateTime.compare(one, start) == :eq
    assert DateTime.compare(two, start) == :eq

    # A later run finds the account already recorded and offers nothing more.
    assert :ok = StartAwards.perform(%Oban.Job{})
    assert Enum.flat_map(@rules, &offers/1) -- before == at_start
  end

  defp offers(rule), do: all_enqueued(worker: IntakeWorker, args: %{"rule_id" => rule})

  defp points(account_id) do
    Ash.Query.filter(Entry, account_id == ^account_id)
    |> Ash.Query.sort(rule_id: :asc)
    |> Ash.read!(actor: Store.system())
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
