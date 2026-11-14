defmodule Patchbay.Offers.Delivery do
  @moduledoc """
  One paid offer Patchbay put in front of a reader: which lease, which
  campaign, on what (`context`, the page or answer it went with), through
  which door (`surface`), to whom, and on which day. Each is written once and
  never changed.

  A reader is a signed agent (`:agent`, its profile), a signed-in person
  (`:person`, their profile) or anyone else (`:visitor`, the keyed hash of
  their address, `PatchbayWeb.ClientAddress.visitor_key/1`). The same lease
  shown to the same reader with the same page on the same day is one
  delivery, so a page read again, refreshed or retried is not a second one.
  Deliveries are how a campaign's daily limit is kept.

  A delivery is Patchbay's own record that it served the offer, not proof the
  reader paid it any attention. Its id is what a signed receipt would name.

  Only Patchbay records one, as the system. A moderator reads them all; an
  advertiser reads them only as counts for their own campaigns' leases
  (`Patchbay.Offers.Lease`'s `delivery_count`), never who they went to.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @hash ~r/\A0x[0-9a-f]{64}\z/

  postgres do
    table("agent_offer_deliveries")
    repo(Patchbay.Repo)

    references do
      reference(:lease, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:campaign_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @hash]
    )

    attribute(:surface, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:page, :markdown, :json, :mcp]]
    )

    attribute(:viewer_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:agent, :person, :visitor]]
    )

    attribute(:viewer, :string, allow_nil?: false, constraints: [max_length: 100])
    attribute(:context, :string, allow_nil?: false, public?: true, constraints: [max_length: 300])
    attribute(:delivered_on, :date, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to :lease, Patchbay.Offers.Lease do
      allow_nil?(false)
      public?(true)
    end

    has_one :campaign, Patchbay.Offers.Campaign do
      source_attribute(:campaign_id)
      destination_attribute(:campaign_id)
    end
  end

  identities do
    identity(:once_a_day, [:lease_id, :viewer_kind, :viewer, :context, :delivered_on])
  end

  actions do
    defaults([:read])

    # The same delivery again keeps the one already written.
    create :record do
      accept([:lease_id, :campaign_id, :surface, :viewer_kind, :viewer, :context])
      change(set_attribute(:delivered_on, &Date.utc_today/0))
      upsert?(true)
      upsert_identity(:once_a_day)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end

    read :today do
      description("One reader's deliveries of these campaigns today.")
      argument(:viewer_kind, :atom, allow_nil?: false)
      argument(:viewer, :string, allow_nil?: false)
      argument(:campaign_ids, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          viewer_kind == ^arg(:viewer_kind) and viewer == ^arg(:viewer) and
            campaign_id in ^arg(:campaign_ids) and delivered_on == today()
        )
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :system))
      authorize_if(Patchbay.Checks.Moderator)
      authorize_if(expr(exists(campaign, agent_profile_id == ^actor(:id))))
    end

    policy action(:record) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
