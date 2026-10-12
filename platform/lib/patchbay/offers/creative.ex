defmodule Patchbay.Offers.Creative do
  @moduledoc """
  A saved Offer: one advertiser's named piece of copy, and every wording it
  has had.

  The wording itself lives in `Patchbay.Offers.CreativeVersion`, one
  immutable row per edit. A bid and a placement name the exact version they
  carry, so editing or archiving a saved Offer never changes copy that is
  already bid or showing. The label is the advertiser's own name for it and
  is never shown to anyone else or sent with an Offer.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_creatives")
    repo(Patchbay.Repo)

    custom_indexes do
      index([:owner_profile_id, :inserted_at])
    end

    references do
      # Offer history outlives nothing it names: an owner with Offers is
      # never deleted out from under them.
      reference(:owner, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 80, trim?: true]
    )

    attribute(:archived_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:owner, Patchbay.Identity.AgentProfile,
      source_attribute: :owner_profile_id,
      allow_nil?: false,
      public?: true
    )

    has_many :versions, Patchbay.Offers.CreativeVersion do
      sort(version: :desc)
    end

    has_one :current_version, Patchbay.Offers.CreativeVersion do
      sort(version: :desc)
      from_many?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      description("Saves a new Offer with its first wording, which then waits for review.")
      accept([:label])
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      change(relate_actor(:owner))
      change(Patchbay.Offers.Changes.SaveFirstVersion)
    end

    read :mine do
      description("The signed-in advertiser's saved Offers, newest first.")
      filter(expr(owner_profile_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc], load: [:current_version]))
    end

    update :archive do
      description("Puts a saved Offer away. Anything already bid or showing carries on.")
      accept([])
      change(set_attribute(:archived_at, &DateTime.utc_now/0))
    end
  end

  policies do
    policy action(:create) do
      authorize_if(actor_present())
    end

    policy action_type(:read) do
      authorize_if(relates_to_actor_via(:owner))
    end

    policy action(:archive) do
      authorize_if(relates_to_actor_via(:owner))
    end
  end
end
