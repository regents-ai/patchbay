defmodule Patchbay.Repo.Migrations.OfferCursorKeepsReading do
  @moduledoc """
  The market's reader no longer stops where the chain disagrees with its
  record: it keeps what it saved first and reads on
  (`Patchbay.Offers.Scanner`). The cursor's stop block,
  `agent_offer_cursors.rescan_from`, goes. Dropping it is safe: Offers has
  never been switched on in production, so the table there has never held a
  row and no value is lost.
  """

  use Ecto.Migration

  # It gives up after five seconds rather than wait behind the cursors
  # table's lock; run migrate again.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:agent_offer_cursors) do
      remove :rescan_from
    end
  end

  def down do
    alter table(:agent_offer_cursors) do
      add :rescan_from, :bigint
    end
  end
end
