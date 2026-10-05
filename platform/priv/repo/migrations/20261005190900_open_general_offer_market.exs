defmodule Patchbay.Repo.Migrations.OpenGeneralOfferMarket do
  @moduledoc """
  Opens the one General market and its three slots. Site markets open the
  first time they are needed; General is always there.
  """

  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO offer_markets (id, scope, policy_revision, inserted_at)
    VALUES (gen_random_uuid(), 'general', 1, (now() AT TIME ZONE 'utc'))
    """)

    execute("""
    INSERT INTO offer_slots (id, market_id, number, active_generation, next_revision)
    SELECT gen_random_uuid(), market.id, slot.number, 0, 0
    FROM offer_markets market, generate_series(1, 3) AS slot(number)
    WHERE market.scope = 'general'
    """)
  end

  def down do
    execute("""
    DELETE FROM offer_slots
    WHERE market_id IN (SELECT id FROM offer_markets WHERE scope = 'general')
    """)

    execute("DELETE FROM offer_markets WHERE scope = 'general'")
  end
end
