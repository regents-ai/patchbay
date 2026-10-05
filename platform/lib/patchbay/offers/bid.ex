defmodule Patchbay.Offers.Bid do
  @moduledoc """
  An advertiser's bid for one slot, in one lane, with one exact version.

  A bid holds its full amount in the shared Credits ledger from the moment it
  is accepted. Its status says where that hold is:

    * `:held` - in an open window, waiting for settlement;
    * `:leading` - the slot's committed next-period leader, still held;
    * `:placed` - won, and its hold became the placement's commitment;
    * `:returned` - did not win or lost its lead; its hold went back in full
      for the reason in `return_reason`.

  The terms the bid was accepted under (the minimum it met, the market's
  rules revision and the placement length) are kept on it, so a later
  change of minimum never rewrites it.

  The idempotency key is the advertiser's own, unique per Credits account,
  and stored with a hash of the request. The same key with the same request
  answers with this bid again; with a different request it is refused.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_bids")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:amount_minor, "offer_bids_amount_positive",
        check: "amount_minor > 0 AND amount_minor >= minimum_minor",
        message: "a bid is positive and meets the minimum it was accepted under"
      )

      check_constraint(:return_reason, "offer_bids_return_shape",
        check: "(status = 'returned') = (return_reason IS NOT NULL)",
        message: "only a returned bid has a reason for returning"
      )
    end

    # One committed next-period leader per slot.
    identity_wheres_to_sql(one_leader_per_slot: "status = 'leading'")

    custom_indexes do
      index([:owner_profile_id, :inserted_at])
      index([:window_id, :amount_minor, :sequence])
      # Lets the slot's next-leader pointer insist it is a bid in that slot.
      index([:id, :slot_id], unique: true, name: "offer_bids_id_slot")
    end

    # A bid is in the same slot and lane as its window.
    custom_statements do
      statement(:bid_in_its_window_slot_and_lane,
        up: """
        ALTER TABLE offer_bids
          ADD CONSTRAINT offer_bids_window_same_slot_and_lane
          FOREIGN KEY (window_id, slot_id, lane)
          REFERENCES offer_bid_windows (id, slot_id, lane)
          ON DELETE RESTRICT
        """,
        down: "ALTER TABLE offer_bids DROP CONSTRAINT offer_bids_window_same_slot_and_lane"
      )
    end

    references do
      reference(:owner, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
      reference(:slot, on_delete: :restrict)
      # Covered by the window, slot and lane key above.
      reference(:window, ignore?: true)
      reference(:target_placement, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # The Credits account the hold is in. The ledger is in the shared
    # payments schema, so this is its id rather than a key into it.
    attribute(:account_id, :uuid, allow_nil?: false)
    attribute(:hold_id, :uuid, allow_nil?: false)

    attribute(:lane, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:immediate, :next_period]]
    )

    attribute(:amount_minor, :integer, allow_nil?: false, public?: true)

    # The terms it was accepted under.
    attribute(:minimum_minor, :integer, allow_nil?: false, public?: true)
    attribute(:opening_minimum_minor, :integer, allow_nil?: false, public?: true)
    attribute(:policy_revision, :integer, allow_nil?: false, public?: true)
    attribute(:duration_us, :integer, allow_nil?: false, public?: true)

    # The slot as the bid found it.
    attribute(:target_generation, :integer, allow_nil?: false, public?: true)
    attribute(:target_next_revision, :integer, allow_nil?: false, public?: true)

    # The order the database accepted bids in; the earlier wins a tie.
    attribute(:sequence, :integer, allow_nil?: false, generated?: true, public?: true)

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 200]
    )

    attribute(:request_sha256, :string, allow_nil?: false)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :held,
      public?: true,
      constraints: [one_of: [:held, :leading, :placed, :returned]]
    )

    attribute(:return_reason, :atom,
      allow_nil?: true,
      public?: true,
      constraints: [
        one_of: [
          :outbid,
          :stale,
          :ineligible,
          :next_leader_replaced,
          :cancelled_by_buyout,
          :placement_removed
        ]
      ]
    )

    attribute(:accepted_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_request, [:account_id, :idempotency_key])
    identity(:unique_hold, [:hold_id])
    identity(:one_leader_per_slot, [:slot_id], where: expr(status == :leading))
  end

  relationships do
    belongs_to(:owner, Patchbay.Identity.AgentProfile,
      source_attribute: :owner_profile_id,
      allow_nil?: false,
      public?: true
    )

    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: false, public?: true)
    belongs_to(:slot, Patchbay.Offers.Slot, allow_nil?: false, public?: true)
    belongs_to(:window, Patchbay.Offers.BidWindow, allow_nil?: false, public?: true)

    # The active placement a bid was made against, if the slot had one.
    belongs_to(:target_placement, Patchbay.Offers.Placement, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    read :mine do
      description("The signed-in advertiser's bids, newest first.")
      filter(expr(owner_profile_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc]))
      pagination(keyset?: true, offset?: true, default_limit: 50, countable: true)
    end
  end

  policies do
    # A bid's amount is public once it leads or is placed; who holds what is
    # read through the market pages, which load only those. The owner reads
    # all of their own bids.
    policy action(:mine) do
      authorize_if(actor_present())
    end

    policy action(:read) do
      authorize_if(expr(status in [:leading, :placed]))
      authorize_if(relates_to_actor_via(:owner))
    end
  end
end
