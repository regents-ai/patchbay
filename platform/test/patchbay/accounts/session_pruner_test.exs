defmodule Patchbay.Accounts.SessionPrunerTest do
  # Sign-in session rows are deleted only once no browser can still hold them: a
  # day longer than the cookie lives after they were last touched. Whatever a row
  # is (never signed in, signed in, revoked), one touched inside that time stays,
  # and so does everyone's current sign-in. As in ash-template.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Accounts.SessionAuthority
  alias Patchbay.Accounts.SessionPruner
  alias Patchbay.Identity

  @day 86_400
  @lifetime Application.compile_env!(:patchbay, :sign_in_lifetime_seconds)
  @actor %{role: :system}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Patchbay.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    %{
      person:
        Identity.upsert_from_privy!(%{
          privy_user_id: "did:privy:session-pruner-#{System.unique_integer([:positive])}",
          wallet_address: "0x" <> String.duplicate("6", 40)
        })
    }
  end

  test "only rows untouched for a day longer than the cookie lives are deleted", %{person: person} do
    past = fn seconds -> DateTime.add(DateTime.utc_now(), -seconds, :second) end
    old = @lifetime + @day + 60
    recent = @lifetime + @day - 60

    kinds = [
      unbound: %{},
      bound: %{agent_profile_id: person.id, generation: 3},
      revoked: %{agent_profile_id: person.id, generation: 2, revoked?: true}
    ]

    rows =
      for {kind, fields} <- kinds, {age, seconds} <- [old: old, recent: recent, today: 0] do
        touched = past.(seconds)
        {revoked?, fields} = Map.pop(fields, :revoked?, false)

        row =
          Ash.Seed.seed!(
            SessionAuthority,
            Map.merge(fields, %{
              lineage_digest: :crypto.strong_rand_bytes(32),
              signed_in_at: fields[:agent_profile_id] && touched,
              revoked_at: (revoked? && touched) || nil,
              inserted_at: touched,
              updated_at: touched
            })
          )

        {{kind, age}, row.id}
      end

    assert :ok = perform_job(SessionPruner, %{})

    left = SessionAuthority |> Ash.read!(actor: @actor) |> MapSet.new(& &1.id)

    for {{kind, age}, id} <- rows do
      assert {kind, age, MapSet.member?(left, id)} == {kind, age, age != :old}
    end

    # A second run finds nothing more to delete.
    assert :ok = SessionAuthority.prune()
    assert SessionAuthority |> Ash.read!(actor: @actor) |> MapSet.new(& &1.id) == left
  end
end
