defmodule Patchbay.DatabaseNamespaceTest do
  use ExUnit.Case, async: false

  alias Patchbay.Forum
  alias Patchbay.Release
  alias Patchbay.Repo

  setup_all do
    unless Repo.config()[:database] == "patchbay_test" <> System.fetch_env!("MIX_TEST_PARTITION") do
      raise "Namespace tests require the prepared disposable database"
    end

    RegentIdentity.Migrator.up(Repo)
    :ok
  end

  setup do
    original = Application.fetch_env!(:patchbay, Repo)
    on_exit(fn -> Application.put_env(:patchbay, Repo, original) end)
    Application.put_env(:patchbay, Repo, Keyword.put(original, :default_prefix, "patchbay"))
    dynamic = start_supervised!({Repo, name: nil, pool_size: 2})
    Repo.put_dynamic_repo(dynamic)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(dynamic)
    # The shared package's raw advisory-lock call uses the named Repo connection.
    # Both connections stay in this test's disposable database and transactions.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Process.whereis(Repo))

    Repo.query!("CREATE SCHEMA patchbay")
    Repo.query!("CREATE TABLE patchbay.forum_sites (LIKE public.forum_sites INCLUDING ALL)")

    for table <- ~w(agent_profiles payment_intents payment_receipts) do
      Repo.query!("CREATE TABLE patchbay.#{table} (LIKE public.#{table} INCLUDING ALL)")
    end

    Repo.query!(
      "CREATE TABLE patchbay.schema_migrations (LIKE public.schema_migrations INCLUDING ALL)"
    )

    Repo.query!("INSERT INTO patchbay.schema_migrations SELECT * FROM public.schema_migrations")

    :ok
  end

  test "payment ownership stays enforced inside the selected product namespace" do
    payer =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "namespace-payer",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    other =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "namespace-other",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    assert {:ok, intent} =
             Patchbay.Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: other},
               actor: payer
             )

    assert {:ok, %{id: id}} = Patchbay.Payments.get_payment_intent(intent.id, actor: payer)
    assert id == intent.id
    assert {:error, _} = Patchbay.Payments.get_payment_intent(intent.id, actor: other)
    assert {:error, _} = Patchbay.Payments.get_payment_intent(intent.id, actor: nil)

    assert [[0]] ==
             Repo.query!("SELECT count(*) FROM public.payment_intents WHERE id=$1", [
               Ecto.UUID.dump!(intent.id)
             ]).rows
  end

  test "the shared identity schema overrides the product default" do
    actor = %RegentPrivy.Session{
      app_id: "namespace-fixture",
      privy_user_id: "namespace-person",
      session_id: "local",
      wallet_addresses: [],
      issued_at: System.system_time(:second) - 1,
      expires_at: System.system_time(:second) + 60
    }

    assert {:ok, profile} = RegentIdentity.sync(actor)

    assert {:ok, %{id: id}} = RegentIdentity.get_my_profile(actor: actor)
    assert id == profile.id
    assert {:ok, nil} = RegentIdentity.get_my_profile(actor: %{actor | privy_user_id: "other"})

    assert [[profile.id]] ==
             Repo.query!("SELECT id::text FROM regent_identity.profiles WHERE id=$1", [
               Ecto.UUID.dump!(profile.id)
             ]).rows
  end

  test "Ash reads and writes the selected namespace while the public decoy stays untouched" do
    selected = Forum.register_site!("namespace.example")

    assert [[0]] ==
             Repo.query!(
               "SELECT count(*) FROM public.forum_sites WHERE origin='namespace.example'"
             ).rows

    Repo.query!(
      "INSERT INTO public.forum_sites SELECT * FROM patchbay.forum_sites WHERE origin='namespace.example'"
    )

    Repo.query!(
      "UPDATE public.forum_sites SET id=gen_random_uuid() WHERE origin='namespace.example'"
    )

    [[public_id]] =
      Repo.query!("SELECT id::text FROM public.forum_sites WHERE origin='namespace.example'").rows

    assert selected.id != public_id
    assert Forum.get_site_by_origin!("namespace.example").id == selected.id
    assert Forum.register_site!("namespace.example").id == selected.id

    assert [[public_id]] ==
             Repo.query!(
               "SELECT id::text FROM public.forum_sites WHERE origin='namespace.example'"
             ).rows

    assert [[selected.id]] ==
             Repo.query!(
               "SELECT id::text FROM patchbay.forum_sites WHERE origin='namespace.example'"
             ).rows
  end

  test "an incomplete imported ledger stops before historical migrations execute" do
    Repo.query!(
      "DELETE FROM patchbay.schema_migrations WHERE version=(SELECT min(version) FROM patchbay.schema_migrations)"
    )

    public = Repo.query!("SELECT version FROM public.schema_migrations ORDER BY version").rows
    imported = Repo.query!("SELECT version FROM patchbay.schema_migrations ORDER BY version").rows

    assert_raise RuntimeError, ~r/Import the complete Patchbay schema/, fn ->
      Release.migrate()
    end

    assert public ==
             Repo.query!("SELECT version FROM public.schema_migrations ORDER BY version").rows

    assert imported ==
             Repo.query!("SELECT version FROM patchbay.schema_migrations ORDER BY version").rows
  end

  test "deployment health follows the selected ledger rather than public history" do
    cache_key = {PatchbayWeb.HealthController, :migrations_status}
    :persistent_term.erase(cache_key)
    on_exit(fn -> :persistent_term.erase(cache_key) end)

    Repo.query!("DELETE FROM public.schema_migrations")

    healthy = PatchbayWeb.HealthController.show(Phoenix.ConnTest.build_conn(), %{})
    assert healthy.status == 200
    assert Jason.decode!(healthy.resp_body)["migrations"] == "current"

    :persistent_term.erase(cache_key)
    Repo.query!("INSERT INTO public.schema_migrations SELECT * FROM patchbay.schema_migrations")
    Repo.query!("DELETE FROM patchbay.schema_migrations")

    pending = PatchbayWeb.HealthController.show(Phoenix.ConnTest.build_conn(), %{})
    assert pending.status == 503
    assert Jason.decode!(pending.resp_body)["migrations"] == "pending"
  end

  test "rollback cannot enter the imported public-qualified history" do
    assert_raise RuntimeError, ~r/Cannot roll back imported history/, fn ->
      Release.rollback(Repo, 0)
    end
  end
end
