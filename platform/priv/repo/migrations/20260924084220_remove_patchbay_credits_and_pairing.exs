defmodule Patchbay.Repo.Migrations.RemovePatchbayCreditsAndPairing do
  @moduledoc """
  Removes Patchbay Credits and agent pairing: the credits ledger, the pairing
  codes, the pairing on a profile, and the record of which currency paid,
  since every payment is now USDC from the payer's own wallet.

  Generated with `mix ash_postgres.generate_migrations`. Nothing names a
  schema, so it follows the schema the deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    drop table(:credit_lines)

    drop table(:pairing_codes)

    alter table(:agent_profiles) do
      remove :paired_person_id
    end

    alter table(:forum_reports) do
      remove :bounty_paid_with
    end

    alter table(:payment_intents) do
      remove :paid_with
    end
  end

  def down do
    raise "irreversible: the credits ledger and pairing codes are gone"
  end
end
