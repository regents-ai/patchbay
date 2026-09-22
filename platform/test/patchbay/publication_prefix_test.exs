defmodule Patchbay.PublicationPrefixTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Patchbay.Forum.{Publication, PublicationGrant}
  alias Patchbay.Repo

  test "new migrations and publication use the configured schema, not public" do
    Sandbox.mode(Repo, :auto)

    try do
      # Empty disposable copies of the pre-change tables; no user rows are copied.
      schema = "publication_fixture_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      previous = Application.fetch_env!(:patchbay, Repo)
      Repo.query!("CREATE SCHEMA #{schema}")

      try do
        for table <- ~w(agent_profiles forum_answer_uses forum_hellos forum_replies forum_reports) do
          Repo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
        end

        additions = %{
          "forum_answer_uses" => ~w(publication_grant_id last_publication_grant_id),
          "forum_hellos" =>
            ~w(publication_grant_id machine_principal client_request_id request_digest operation_id operation_name submission_transport target_interface agent_environment),
          "forum_replies" =>
            ~w(publication_grant_id machine_principal operation_id operation_name submission_transport target_interface agent_environment),
          "forum_reports" => ~w(publication_grant_id)
        }

        for {table, columns} <- additions, column <- columns do
          Repo.query!("ALTER TABLE #{schema}.#{table} DROP COLUMN #{column}")
        end

        migrations = [
          {20_260_922_072_932, Patchbay.Repo.Migrations.PublicationAuthorizations,
           "20260922072932_publication_authorizations.exs"},
          {20_260_922_074_436, Patchbay.Repo.Migrations.OutcomeGrantProvenance,
           "20260922074436_outcome_grant_provenance.exs"}
        ]

        for {version, module, file} <- migrations do
          unless Code.ensure_loaded?(module),
            do: Code.require_file(Path.join("priv/repo/migrations", file))

          assert :ok = Ecto.Migrator.up(Repo, version, module, prefix: schema, log: false)
        end

        assert Repo.query!(
                 "SELECT confrelid::regclass::text FROM pg_constraint WHERE conrelid = $1::text::regclass AND conname = 'forum_publication_grants_approver_id_fkey'",
                 [schema <> ".forum_publication_grants"]
               ).rows == [[schema <> ".agent_profiles"]]

        Application.put_env(:patchbay, Repo, Keyword.put(previous, :default_prefix, schema))

        actor =
          Patchbay.Identity.upsert_from_wallet!(%{
            wallet_address: "0x" <> String.duplicate("d", 40)
          })

        approver =
          Patchbay.Identity.upsert_from_privy!(%{
            privy_user_id: "prefix-fixture",
            wallet_address: "0x" <> String.duplicate("c", 40)
          })

        grant =
          Ash.create!(
            PublicationGrant,
            %{
              subject_wallet: actor.wallet_address,
              mode: :task,
              purpose: "Prefix fixture",
              operations: [:hello],
              public_confirmation: true
            },
            action: :approve,
            actor: approver
          )

        assert {:ok, hello} =
                 Publication.publish(
                   :hello,
                   %{
                     "publication_grant_id" => grant.id,
                     "name" => "Prefix fixture",
                     "visibility" => "public",
                     "client_request_id" => Ecto.UUID.generate(),
                     "target_interface" => "none",
                     "agent_environment" => "fixture"
                   },
                   actor
                 )

        assert hello.publication_grant_id == grant.id

        assert Repo.query!("SELECT count(*) FROM public.forum_publication_grants WHERE id = $1", [
                 Ecto.UUID.dump!(grant.id)
               ]).rows == [[0]]

        assert Repo.query!("SELECT count(*) FROM #{schema}.forum_hellos WHERE id = $1", [
                 Ecto.UUID.dump!(hello.id)
               ]).rows == [[1]]
      after
        Application.put_env(:patchbay, Repo, previous)
        Repo.query!("DROP SCHEMA #{schema} CASCADE")
      end
    after
      Sandbox.mode(Repo, :manual)
    end
  end
end
