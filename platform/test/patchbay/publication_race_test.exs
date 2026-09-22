defmodule Patchbay.PublicationRaceTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Patchbay.Forum.{Publication, PublicationGrant}
  alias Patchbay.Repo

  test "a revocation committing before admission prevents publication on independent SQL connections" do
    Sandbox.unboxed_run(Repo, fn ->
      actor =
        Patchbay.Identity.upsert_from_wallet!(%{
          wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
        })

      approver =
        Patchbay.Identity.upsert_from_privy!(%{
          privy_user_id: "race-#{Ecto.UUID.generate()}",
          wallet_address: "0x" <> String.duplicate("e", 40)
        })

      grant =
        Ash.create!(
          PublicationGrant,
          %{
            subject_wallet: actor.wallet_address,
            mode: :task,
            purpose: "Race fixture",
            operations: [:hello],
            public_confirmation: true
          },
          action: :approve,
          actor: approver
        )

      parent = self()

      try do
        revoker =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Ash.update!(grant, %{},
                  action: :revoke,
                  actor: approver,
                  return_notifications?: true
                )

                [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                send(parent, {:revoking, pid})

                receive do
                  :commit -> :ok
                after
                  5000 -> raise "release timed out"
                end
              end)
            end)
          end)

        assert_receive {:revoking, revoker_pid}, 2000

        publisher =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
              send(parent, {:publishing, pid})

              Publication.publish(
                :hello,
                %{
                  "publication_grant_id" => grant.id,
                  "name" => "Race fixture",
                  "visibility" => "public",
                  "client_request_id" => Ecto.UUID.generate(),
                  "target_interface" => "none",
                  "agent_environment" => "fixture"
                },
                actor
              )
            end)
          end)

        assert_receive {:publishing, publisher_pid}, 2000
        refute publisher_pid == revoker_pid
        assert Task.yield(publisher, 100) == nil
        send(revoker.pid, :commit)
        assert {:ok, :ok} = Task.await(revoker)
        assert {:error, :publication_not_authorized} = Task.await(publisher)

        assert Repo.query!("SELECT count(*) FROM forum_hellos WHERE publication_grant_id = $1", [
                 Ecto.UUID.dump!(grant.id)
               ]).rows == [[0]]
      after
        Repo.query!("DELETE FROM forum_publication_grants WHERE id = $1", [
          Ecto.UUID.dump!(grant.id)
        ])

        Repo.query!("DELETE FROM agent_profiles WHERE id = ANY($1)", [
          [Ecto.UUID.dump!(actor.id), Ecto.UUID.dump!(approver.id)]
        ])
      end
    end)
  end
end
