defmodule PatchbayWeb.MCPEventsRaceTest do
  @moduledoc """
  Two events subscription saves, or a save and a removal, in separate
  database transactions at once, as they happen in production. These tests
  run outside the test sandbox (its one shared connection would put both in
  the same transaction), so what they write is committed. They are tagged
  `:committed` and left out of the main run: `scripts/committed_tests.sh`
  runs them in a database of their own and drops that database afterwards,
  so nothing they write is ever removed row by row.

  Each holds one transaction at a lock the save takes, waits until the others
  are waiting on a lock too, then lets go, so the interleaving is the same on
  every run.
  """

  use ExUnit.Case, async: false

  @moduletag :committed

  alias Ecto.Adapters.SQL.Sandbox
  alias Patchbay.Forum.EventSubscription
  alias Patchbay.Forum.Principal
  alias Patchbay.Repo
  alias PatchbayWeb.MCP.Events

  setup do
    Sandbox.mode(Repo, :auto)
    actor = Patchbay.AssistFixtures.paired_agent()

    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    %{actor: actor}
  end

  test "at the account's edge, two subscribes at once let only one in", %{actor: actor} do
    for n <- 1..19, do: seed!(actor, "https://hooks-#{n}.example/in")

    # Both pass the first look (19 live) and wait at their callback's challenge.
    tasks =
      for n <- 1..2,
          do: Task.async(fn -> Events.subscribe(params("https://answers.test/#{n}"), actor) end)

    challenged =
      for _ <- tasks do
        assert_receive {:challenged, pid}, 5_000
        pid
      end

    # The pairing row is the last lock a save takes, after it counts again.
    # Held here, both saves are inside their transactions at once: without the
    # account's lock both have counted 19 by now; with it, one waits for the
    # other before it counts.
    holder =
      hold(fn ->
        RegentAgents.Authority.lock(
          Repo,
          actor.pairing_id,
          actor.privy_user_id,
          actor.wallet_address
        )
      end)

    for pid <- challenged, do: send(pid, :answer)
    await_waiting(2)
    release(holder)

    answers = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.count(answers, &match?({:ok, %{"id" => _}}, &1)) == 1

    assert Enum.count(
             answers,
             &match?({:error, -32_000, _, %{code: "too_many_subscriptions"}}, &1)
           ) == 1

    assert live_count(actor) == 20
  end

  test "a refresh that meets a removal keeps its place in the stream", %{actor: actor} do
    url = "https://echo.test/kept"
    kept = seed!(actor, url, arguments: %{}, delivered_seq: 42)

    # The hourly removal ends the row in its own transaction, which takes no
    # account lock; the refresh reads the row before that commits.
    remover = hold(fn -> Ash.destroy!(kept, action: :forget, authorize?: false) end)
    refresh = Task.async(fn -> Events.subscribe(params(url), actor) end)
    await_waiting(1)
    release(remover)

    assert {:ok, %{"id" => id}} = Task.await(refresh, 15_000)
    assert id == kept.id

    assert {:ok, %EventSubscription{delivered_seq: 42}} =
             Patchbay.Forum.get_event_subscription(id, authorize?: false)
  end

  # Runs `lock` in a transaction of its own and holds it until released.
  defp hold(lock) do
    test = self()

    pid =
      spawn_link(fn ->
        Repo.transaction(fn ->
          lock.()
          send(test, {:holding, self()})

          receive do
            :release -> :ok
          end
        end)

        send(test, {:released, self()})
      end)

    assert_receive {:holding, ^pid}, 5_000
    pid
  end

  defp release(pid) do
    send(pid, :release)
    assert_receive {:released, ^pid}, 5_000
  end

  # Until `count` other transactions of this database wait on a lock.
  defp await_waiting(count, tries \\ 200) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      waiting >= count -> :ok
      tries == 0 -> flunk("#{waiting} of #{count} saves were waiting on a lock")
      true -> Process.sleep(10) && await_waiting(count, tries - 1)
    end
  end

  defp params(url) do
    %{
      "name" => "reply_created",
      "arguments" => %{},
      "delivery" => %{
        "mode" => "webhook",
        "url" => url,
        "secret" => "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
      }
    }
  end

  defp seed!(actor, url, opts \\ []) do
    owner_id = Principal.for_profile(actor.beneficiary_profile_id)
    arguments = Keyword.get(opts, :arguments, %{"thread_ids" => [Ash.UUID.generate()]})
    {:ok, id} = Regent.MCPEvents.subscription_id(owner_id, "reply_created", arguments, url)
    now = DateTime.utc_now()

    Ash.Seed.seed!(EventSubscription, %{
      id: id,
      owner_id: owner_id,
      name: "reply_created",
      arguments: arguments,
      url: url,
      secret_ciphertext:
        Patchbay.Forum.EventSecret.seal("whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))),
      expires_at: DateTime.add(now, 3600, :second),
      verified_at: now,
      delivered_seq: Keyword.get(opts, :delivered_seq, 0)
    })
  end

  defp live_count(actor) do
    owner_id = Principal.for_profile(actor.beneficiary_profile_id)

    EventSubscription
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.owner_id == owner_id))
  end
end
