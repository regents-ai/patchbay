defmodule Patchbay.Offers.Bid do
  @moduledoc """
  An advertiser's bid for one slot, in one lane, with one exact version.

  A bid's USDC is held in `PatchbayOffersEscrow` on Base. The bidder's wallet
  signs one USDC authorization for the amount with the bid's id as its nonce,
  so the bid id is also its escrow commitment id, and Patchbay commits it.
  `funding` says where that commit is:

    * `:awaiting_funds` - signed, and the commit has not confirmed yet;
    * `:funded` - the commit confirmed in `commit_tx_hash`; only a funded bid
      can win;
    * `:commit_failed` - the commit did not go through, so nothing moved.

  Its status says where it stands in the market:

    * `:held` - in an open window, waiting for settlement;
    * `:leading` - the slot's committed next-period leader;
    * `:placed` - won; its commitment carries on as the placement's, which
      records the settlement;
    * `:returned` - did not win or lost its lead, for the reason in
      `return_reason`; a funded one went back in full in `release_tx_hash`.

  The terms the bid was accepted under (the minimum it met, the market's
  rules revision and the placement length) are kept on it, so a later
  change of minimum never rewrites it.

  The idempotency key is the advertiser's own, unique per advertiser, and
  stored with a hash of the request. The same key with the same request
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

      check_constraint(:funding, "offer_bids_funding_shape",
        check: """
        (funding = 'funded') = (commit_tx_hash IS NOT NULL)
          AND (status NOT IN ('leading', 'placed') OR funding = 'funded')
          AND (release_tx_hash IS NULL OR (status = 'returned' AND funding = 'funded'))
        """,
        message:
          "only a funded bid can lead or be placed, and only a funded returned bid has a release"
      )

      check_constraint(:payer_address, "offer_bids_payer_address_format",
        check: "payer_address ~ '^0x[0-9a-f]{40}$'",
        message: "the payer is a lowercase wallet address"
      )

      check_constraint(:commit_tx_hash, "offer_bids_tx_hash_format",
        check:
          "(commit_tx_hash IS NULL OR commit_tx_hash ~ '^0x[0-9a-f]{64}$') AND (release_tx_hash IS NULL OR release_tx_hash ~ '^0x[0-9a-f]{64}$')",
        message: "a transaction hash is lowercase hex"
      )

      check_constraint(:return_reason, "offer_bids_return_shape",
        check:
          "(status = 'returned') = (return_reason IS NOT NULL) AND (status <> 'returned' OR resolved_at IS NOT NULL)",
        message:
          "only a returned bid has a reason for returning, and it records when it came back"
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

    # The wallet that signed the USDC authorization; everything returned
    # goes back to it.
    attribute(:payer_address, :string, allow_nil?: false)

    attribute(:funding, :atom,
      allow_nil?: false,
      default: :awaiting_funds,
      public?: true,
      constraints: [one_of: [:awaiting_funds, :funded, :commit_failed]]
    )

    attribute(:commit_tx_hash, :string, allow_nil?: true, public?: true)
    attribute(:release_tx_hash, :string, allow_nil?: true, public?: true)

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
    identity(:unique_request, [:owner_profile_id, :idempotency_key])
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
