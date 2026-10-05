defmodule Patchbay.Offers.Slot do
  @moduledoc """
  One of a market's three numbered positions.

  A slot points at its active placement, if any, and at its committed
  next-period leader, if any. Both pointers change only under this row's
  lock, inside the transaction that changes what they point at.

  Two counters let a bid name the state it was made against:

    * `active_generation` rises whenever the active owner changes or the slot
      empties, so a bid made against an earlier owner is stale;
    * `next_revision` rises whenever the committed next-period leader
      changes, so a next-period bid made against an earlier leader is stale
      without disturbing bids against the active owner.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_slots")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:number, "offer_slots_number_range",
        check: "number BETWEEN 1 AND 3",
        message: "a slot is numbered 1, 2 or 3"
      )
    end

    # Both pointers name records in this same slot. Each key pairs the
    # pointer with this slot's id, so a placement or bid of another slot can
    # never be pointed at.
    custom_statements do
      statement(:active_placement_in_this_slot,
        up: """
        ALTER TABLE offer_slots
          ADD CONSTRAINT offer_slots_active_placement_same_slot
          FOREIGN KEY (active_placement_id, id)
          REFERENCES offer_placements (id, slot_id)
          ON DELETE RESTRICT
        """,
        down: "ALTER TABLE offer_slots DROP CONSTRAINT offer_slots_active_placement_same_slot"
      )

      statement(:next_bid_in_this_slot,
        up: """
        ALTER TABLE offer_slots
          ADD CONSTRAINT offer_slots_next_bid_same_slot
          FOREIGN KEY (next_bid_id, id)
          REFERENCES offer_bids (id, slot_id)
          ON DELETE RESTRICT
        """,
        down: "ALTER TABLE offer_slots DROP CONSTRAINT offer_slots_next_bid_same_slot"
      )
    end

    references do
      reference(:market, on_delete: :restrict)
      reference(:active_placement, ignore?: true)
      reference(:next_bid, ignore?: true)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:number, :integer, allow_nil?: false, public?: true)
    attribute(:active_generation, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:next_revision, :integer, allow_nil?: false, default: 0, public?: true)
  end

  identities do
    identity(:unique_number, [:market_id, :number])
  end

  relationships do
    belongs_to(:market, Patchbay.Offers.Market, allow_nil?: false, public?: true)
    belongs_to(:active_placement, Patchbay.Offers.Placement, allow_nil?: true, public?: true)
    belongs_to(:next_bid, Patchbay.Offers.Bid, allow_nil?: true, public?: true)
    has_many(:placements, Patchbay.Offers.Placement)
  end

  actions do
    defaults([:read])

    create :open do
      description("Makes one of a market's three slots, or hands back the one it has.")
      accept([:market_id, :number])
      upsert?(true)
      upsert_identity(:unique_number)
      upsert_fields([:number])
    end
  end

  policies do
    # Slots are public. They are written only inside Patchbay's own market
    # actions, which skip authorization deliberately.
    policy action_type(:read) do
      authorize_if(always())
    end
  end
end
