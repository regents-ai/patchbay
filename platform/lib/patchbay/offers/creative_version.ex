defmodule Patchbay.Offers.CreativeVersion do
  @moduledoc """
  One wording of a saved Offer, never changed once saved.

  The text is normalized and checked by `Patchbay.Offers.CreativeText` before
  it is kept, and the database holds the same limits again. Every new
  version waits for a safety review (`Patchbay.Offers.Review`) before it can
  be bid with, and a site market also needs its own relevance review.

  A moderator may block a version. A blocked version never shows again, is
  never promoted into a slot, and the same text cannot be saved again under
  another label.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_creative_versions")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:text, "offer_creative_versions_text_limits",
        check:
          "char_length(text) BETWEEN 1 AND 160 AND octet_length(text) <= 640 AND btrim(text) <> '' AND text IS NFC NORMALIZED",
        message: "is not an Offer's text"
      )
    end

    custom_indexes do
      index([:text_sha256])
      index([:blocked_at])
    end

    references do
      reference(:creative, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:version, :integer, allow_nil?: false, public?: true)
    attribute(:text, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    # The SHA-256 of the normalized text, hex, so a blocked text is known
    # again whatever it is saved under.
    attribute(:text_sha256, :string, allow_nil?: false, public?: true)

    attribute(:code_points, :integer, allow_nil?: false, public?: true)
    attribute(:byte_count, :integer, allow_nil?: false, public?: true)

    # The links written in full, in order, and the address-like words that
    # are not links; both are reviewed.
    attribute(:urls, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:bare_addresses, {:array, :string}, allow_nil?: false, default: [], public?: true)

    attribute(:blocked_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:block_reason, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 500]
    )

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_version, [:creative_id, :version])
  end

  relationships do
    belongs_to(:creative, Patchbay.Offers.Creative, allow_nil?: false, public?: true)

    has_many :reviews, Patchbay.Offers.Review do
      destination_attribute(:version_id)
    end

    has_many :bids, Patchbay.Offers.Bid do
      destination_attribute(:version_id)
    end

    has_many :placements, Patchbay.Offers.Placement do
      destination_attribute(:version_id)
    end
  end

  actions do
    defaults([:read])

    create :save do
      description(
        "Saves a new wording of one of the advertiser's Offers, which then waits for review."
      )

      accept([])
      argument(:creative_id, :uuid, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      change(set_attribute(:creative_id, arg(:creative_id)))
      change(Patchbay.Offers.Changes.NormalizeText)
      change(Patchbay.Offers.Changes.NextVersion)
      change(Patchbay.Offers.Changes.RequestSafetyReview)
    end

    update :block do
      description("Blocks this wording everywhere, at once.")
      accept([])
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 500])
      change(set_attribute(:blocked_at, &DateTime.utc_now/0))
      change(set_attribute(:block_reason, arg(:reason)))
    end
  end

  policies do
    # The owner reads their own versions. Showing a version in a market or a
    # response is Patchbay's own read, which skips authorization deliberately
    # and only ever reads copy that is placed or leading.
    policy action_type(:read) do
      authorize_if(expr(creative.owner_profile_id == ^actor(:id)))
    end

    # Saving checks the owner itself, under the saved Offer's lock.
    policy action(:save) do
      authorize_if(actor_present())
    end
  end
end
