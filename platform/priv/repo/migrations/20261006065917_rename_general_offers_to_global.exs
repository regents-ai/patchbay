defmodule Patchbay.Repo.Migrations.RenameGeneralOffersToGlobal do
  @moduledoc """
  The General market and its slots are now the Global Agent Offer Slots:
  the stored scope, its one-market index and the deliveries' count column
  take the new name.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:offer_markets, [:scope], name: "offer_markets_one_general")

    execute("UPDATE offer_markets SET scope = 'global' WHERE scope = 'general'")
    execute("UPDATE offer_delivery_items SET scope = 'global' WHERE scope = 'general'")

    create index(:offer_markets, [:scope],
             name: "offer_markets_one_global",
             unique: true,
             where: "scope = 'global'"
           )

    rename table(:offer_deliveries), :general_opportunities, to: :global_opportunities
  end

  def down do
    rename table(:offer_deliveries), :global_opportunities, to: :general_opportunities

    drop_if_exists index(:offer_markets, [:scope], name: "offer_markets_one_global")

    execute("UPDATE offer_delivery_items SET scope = 'general' WHERE scope = 'global'")
    execute("UPDATE offer_markets SET scope = 'general' WHERE scope = 'global'")

    create index(:offer_markets, [:scope],
             name: "offer_markets_one_general",
             unique: true,
             where: "scope = 'general'"
           )
  end
end
