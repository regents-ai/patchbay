defmodule Patchbay.Offers.Placement do
  @moduledoc """
  One winning bid's run in a slot: a fresh 72 hours from `starts_at`.

  A placement is shown while `starts_at <= now < expires_at`, it is still
  `:active`, and its version is approved and not blocked. Expiry is read from
  the clock, so a late job never keeps old copy showing.

  Its Credits are its bid's hold, carried over to the placement's id. When it
  ends, the split is kept here, always adding up to what was bid, and the
  hold is settled the same way in the same transaction:

    * `:expired` - all of it consumed for time;
    * `:bought_out` - the unused time returned, the rest consumed;
    * `:removed_for_policy` - nothing returned; the used time consumed and
      the unused time forfeited.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # A placement is ended by the job queued for its expiry when it started.
  # The minute sweep ends any whose job was lost, and every bid and removal
  # in its slot ends it first anyway. Ending one starts its slot's waiting
  # next-period leader.
  oban do
    triggers do
      trigger :expire do
        action(:expire)
        queue(:offers_settlement)
        where(expr(status == :active and expires_at <= now()))
        max_attempts(5)
        lock_for_update?(false)
        worker_module_name(Patchbay.Offers.Placement.Workers.Expire)
        scheduler_module_name(Patchbay.Offers.Placement.Schedulers.Expire)
      end
    end
  end

  postgres do
    table("offer_placements")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:amount_minor, "offer_placements_amount_positive",
        check: "amount_minor > 0",
        message: "a placement's bid is positive"
      )

      check_constraint(:expires_at, "offer_placements_full_term",
        check: "expires_at = starts_at + (duration_us * interval '1 microsecond')",
        message: "a placement runs for its full term from its start"
      )

      check_constraint(:status, "offer_placements_settlement_conserves",
        check: """
        CASE status
          WHEN 'active' THEN ended_at IS NULL AND returned_minor IS NULL AND consumed_minor IS NULL AND forfeited_minor IS NULL
          ELSE ended_at IS NOT NULL
            AND returned_minor >= 0 AND consumed_minor >= 0 AND forfeited_minor >= 0
            AND returned_minor + consumed_minor + forfeited_minor = amount_minor
            AND (status <> 'expired' OR (returned_minor = 0 AND forfeited_minor = 0))
            AND (status <> 'bought_out' OR forfeited_minor = 0)
            AND (status <> 'removed_for_policy' OR returned_minor = 0)
        END
        """,
        message: "an ended placement settles exactly what was bid"
      )
    end

    # One active placement per slot.
    identity_wheres_to_sql(one_active_per_slot: "status = 'active'")

    custom_indexes do
      index([:expires_at], where: "status = 'active'")
      index([:owner_profile_id, :status, :starts_at])
      index([:slot_id, :starts_at])
      # Lets the slot's active pointer insist it is a placement in that slot.
      index([:id, :slot_id], unique: true, name: "offer_placements_id_slot")
    end

    references do
      reference(:owner, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
      reference(:slot, on_delete: :restrict)
      reference(:bid, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:amount_minor, :integer, allow_nil?: false, public?: true)

    # The terms it was won under, from its bid.
    attribute(:minimum_minor, :integer, allow_nil?: false, public?: true)
    attribute(:policy_revision, :integer, allow_nil?: false, public?: true)
    attribute(:duration_us, :integer, allow_nil?: false, public?: true)

    # The slot's active generation this placement began.
    attribute(:generation, :integer, allow_nil?: false, public?: true)

    attribute(:starts_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:ended_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      constraints: [one_of: [:active, :expired, :bought_out, :removed_for_policy]]
    )

    attribute(:returned_minor, :integer, allow_nil?: true, public?: true)
    attribute(:consumed_minor, :integer, allow_nil?: true, public?: true)
    attribute(:forfeited_minor, :integer, allow_nil?: true, public?: true)
  end

  identities do
    identity(:unique_bid, [:bid_id])
    identity(:one_active_per_slot, [:slot_id], where: expr(status == :active))
  end

  relationships do
    belongs_to(:owner, Patchbay.Identity.AgentProfile,
      source_attribute: :owner_profile_id,
      allow_nil?: false,
      public?: true
    )

    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: false, public?: true)
    belongs_to(:slot, Patchbay.Offers.Slot, allow_nil?: false, public?: true)
    belongs_to(:bid, Patchbay.Offers.Bid, allow_nil?: false, public?: true)
    has_many(:delivery_items, Patchbay.Offers.DeliveryItem)
  end

  calculations do
    calculate(:showing?, :boolean, expr(status == :active and expires_at > now()), public?: true)
  end

  actions do
    defaults([:read])

    create :start do
      description("Starts a winning bid's fresh 72 hours, under its slot's lock.")

      accept([
        :owner_profile_id,
        :version_id,
        :slot_id,
        :bid_id,
        :amount_minor,
        :minimum_minor,
        :policy_revision,
        :duration_us,
        :generation,
        :starts_at,
        :expires_at
      ])
    end

    update :finish do
      description("Ends a placement with how its Credits divided.")
      accept([:status, :ended_at, :returned_minor, :consumed_minor, :forfeited_minor])
    end

    update :expire do
      description("Ends this placement at its expiry and starts its slot's next leader.")
      require_atomic?(false)
      manual(Patchbay.Offers.Changes.AdvanceSlot)
    end

    read :mine do
      description("The signed-in advertiser's placements, newest first.")
      filter(expr(owner_profile_id == ^actor(:id)))
      prepare(build(sort: [starts_at: :desc]))
      pagination(keyset?: true, offset?: true, default_limit: 50, countable: true)
    end

    read :showing do
      description("""
      The placements that may be returned for a site at one moment: that
      site's own and Global's, each running at that moment, its wording not
      blocked and its safety allow still fresh. A site placement also needs a
      fresh allow saying it suits that site's market.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:at, :utc_datetime_usec, allow_nil?: false)

      filter(
        expr(
          status == :active and starts_at <= ^arg(:at) and expires_at > ^arg(:at) and
            is_nil(version.blocked_at) and
            exists(
              version.reviews,
              kind == :safety and decision == :allow and fresh_until > ^arg(:at)
            ) and
            (slot.market.scope == :global or
               (slot.market.site_id == ^arg(:site_id) and
                  exists(
                    version.reviews,
                    kind == :relevance and decision == :allow and fresh_until > ^arg(:at) and
                      market_id == parent(slot.market_id)
                  )))
        )
      )

      prepare(build(load: [:version, slot: :market]))
    end
  end

  policies do
    # Placements are public: what is showing, for how much and until when.
    policy action_type(:read) do
      authorize_if(always())
    end
  end

  field_policies do
    # Who owns a placement and how its Credits were settled are read only by
    # that owner. A removal records its own split for moderators.
    field_policy [:owner_profile_id, :returned_minor, :consumed_minor, :forfeited_minor] do
      authorize_if(expr(owner_profile_id == ^actor(:id)))
    end

    field_policy :* do
      authorize_if(always())
    end
  end
end
