defmodule Patchbay.Accounts.SessionAuthorityTest do
  # A browser's sign-in through every step it can take, as in ash-template. An
  # exhausted lineage is revoked and refused in one transaction, and the
  # revocation must commit although the answer is an error.
  use ExUnit.Case, async: true

  alias Patchbay.Accounts.SessionAuthority
  alias Patchbay.Identity
  alias Patchbay.Repo

  @maximum_generation 9_223_372_036_854_775_807

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  test "a person signs in, refreshes, signs in as someone else and signs out" do
    first = person("a")
    second = person("b")

    {:bootstrap, claim} = SessionAuthority.renew(nil)
    assert {:current, ^claim} = SessionAuthority.renew(claim)
    assert {claim.lineage, nil, nil} == SessionAuthority.resolve(claim)

    assert {:ok, :bind, bound} = SessionAuthority.sign_in(claim, first.id, DateTime.utc_now())
    assert {:error, :superseded} = SessionAuthority.renew(claim)
    assert {_lineage, %{id: first_id}, %DateTime{}} = SessionAuthority.resolve(bound)
    assert first_id == first.id

    assert {:ok, :refresh, refreshed} =
             SessionAuthority.sign_in(bound, first.id, DateTime.utc_now())

    assert refreshed.generation == bound.generation + 1
    assert {:error, :superseded} = SessionAuthority.sign_in(bound, first.id, DateTime.utc_now())
    assert SessionAuthority.leased_profile(refreshed.lineage, first.id).id == first.id

    topic = SessionAuthority.topic(refreshed.lineage)
    assert {:switch, ^topic} = SessionAuthority.sign_in(refreshed, second.id, DateTime.utc_now())
    assert {nil, nil, nil} = SessionAuthority.resolve(refreshed)
    assert SessionAuthority.leased_profile(refreshed.lineage, first.id) == nil

    {:bootstrap, fresh} = SessionAuthority.renew(nil)

    assert {:ok, :bind, signed_in} =
             SessionAuthority.sign_in(fresh, second.id, DateTime.utc_now())

    assert SessionAuthority.revoke(signed_in) == SessionAuthority.topic(signed_in.lineage)
    assert {:error, :reset} = SessionAuthority.renew(signed_in)
    assert {:error, :reset} = SessionAuthority.sign_in(signed_in, second.id, DateTime.utc_now())
  end

  test "a sign-in lasts its lifetime from when it was made, and refreshing never extends it" do
    lifetime = Application.fetch_env!(:patchbay, :sign_in_lifetime_seconds)
    person = person("c")
    made = DateTime.add(DateTime.utc_now(), 60 - lifetime)

    {:bootstrap, claim} = SessionAuthority.renew(nil)
    {:ok, :bind, bound} = SessionAuthority.sign_in(claim, person.id, made)
    {:ok, :refresh, refreshed} = SessionAuthority.sign_in(bound, person.id, DateTime.utc_now())

    lapses_at = DateTime.add(made, lifetime)
    assert {_lineage, %{}, ^lapses_at} = SessionAuthority.resolve(refreshed)

    {:bootstrap, claim} = SessionAuthority.renew(nil)
    {:ok, :bind, lapsed} = SessionAuthority.sign_in(claim, person.id, DateTime.add(made, -61))

    assert {nil, nil, nil} = SessionAuthority.resolve(lapsed)
    assert {:error, :reset} = SessionAuthority.renew(lapsed)
    assert SessionAuthority.leased_profile(lapsed.lineage, person.id) == nil
  end

  test "a claim no server minted is none, and one the database has never seen past its first step is refused" do
    {:bootstrap, claim} = SessionAuthority.renew(nil)
    session = SessionAuthority.session(claim)

    assert SessionAuthority.claim(session) == claim

    for altered <- [
          Map.put(session, "live_socket_id", "session_authority:another"),
          Map.put(session, "session_lineage", claim.lineage <> "="),
          Map.put(session, "session_generation", -1),
          Map.delete(session, "session_generation")
        ] do
      assert SessionAuthority.claim(altered) == nil
      assert SessionAuthority.claim_shaped?(altered)
    end

    refute SessionAuthority.claim_shaped?(%{"forum_session_id" => "x"})

    unseen = %{lineage: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
    assert {:error, :reset} = SessionAuthority.renew(Map.put(unseen, :generation, 4))
    assert {:current, _claim} = SessionAuthority.renew(Map.put(unseen, :generation, 0))
  end

  test "an exhausted lineage is refused and stays revoked" do
    person = person("e")
    {:bootstrap, claim} = SessionAuthority.renew(nil)
    {:ok, :bind, bound} = SessionAuthority.sign_in(claim, person.id, DateTime.utc_now())
    digest = :crypto.hash(:sha256, bound.lineage)

    Repo.query!(
      "UPDATE session_authorities SET generation = $1 WHERE lineage_digest = $2",
      [@maximum_generation, digest]
    )

    exhausted = %{bound | generation: @maximum_generation}
    assert {:error, :reset} = SessionAuthority.sign_in(exhausted, person.id, DateTime.utc_now())

    assert %{rows: [[revoked_at]]} =
             Repo.query!(
               "SELECT revoked_at FROM session_authorities WHERE lineage_digest = $1",
               [digest]
             )

    assert revoked_at
    assert {:error, :reset} = SessionAuthority.sign_in(exhausted, person.id, DateTime.utc_now())
  end

  defp person(digit) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:session-authority-#{System.unique_integer([:positive])}",
      wallet_address: "0x" <> String.duplicate(digit, 40)
    })
  end
end
