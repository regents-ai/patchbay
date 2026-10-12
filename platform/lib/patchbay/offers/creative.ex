defmodule Patchbay.Offers.Creative do
  @moduledoc """
  A saved Offer: one advertiser's named piece of copy, and every wording it
  has had.

  The wording itself lives in `Patchbay.Offers.CreativeVersion`, one
  immutable row per edit. A bid and a placement name the exact version they
  carry, so editing or archiving a saved Offer never changes copy that is
  already bid or showing. The label is the advertiser's own name for it and
  is never shown to anyone else or sent with an Offer.

  An Offer none of whose wordings was ever bid with can be deleted, for
  good, with every wording and screening it had. A block of its words, and
  the log of its turn-downs, stay.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  # A new or deleted Offer tells the open admin page to read again.
  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:create, ["offers:creatives"], transform: &__MODULE__.changed_message/1)
    publish(:delete, ["offers:creatives"], transform: &__MODULE__.changed_message/1)
  end

  @doc "The PubSub topic a new or deleted Offer is announced on."
  @spec topic() :: String.t()
  def topic, do: "offers:creatives"

  @doc false
  def changed_message(_notification), do: :offer_creatives_changed

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

    # The key the saving form or agent made for this Offer: the same key
    # again answers with this Offer instead of saving another.
    attribute(:request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 8, max_length: 100]
    )

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_request, [:owner_profile_id, :request_key])
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

  aggregates do
    # Whether any wording of it was ever bid with, which keeps it from deletion.
    exists(:has_bids?, [:versions, :bids], public?: true)
  end

  actions do
    defaults([:read])

    action :save, :struct do
      description("""
      Saves a new Offer with its first wording, which is then screened.
      The same request key again answers with the Offer it saved, saves
      nothing more and uses no daily save.
      """)

      constraints(instance_of: __MODULE__)
      transaction?(true)

      argument(:label, :string, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      argument(:request_key, :string,
        allow_nil?: false,
        constraints: [min_length: 8, max_length: 100]
      )

      run(fn input, context -> Patchbay.Offers.Saving.offer(input.arguments, context.actor) end)
    end

    create :create do
      description("Writes a new Offer and its first wording, for a request key not used before.")
      accept([:label, :request_key])
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

    destroy :delete do
      description("""
      Deletes a saved Offer for good, with every wording and screening it
      had. An Offer any of whose wordings was ever bid with cannot be deleted.
      """)

      require_atomic?(false)
      validate(Patchbay.Offers.Validations.NeverBid)
    end
  end

  policies do
    policy action([:save, :create]) do
      authorize_if(actor_present())
    end

    policy action_type(:read) do
      authorize_if(relates_to_actor_via(:owner))
    end

    policy action([:archive, :delete]) do
      authorize_if(relates_to_actor_via(:owner))
    end
  end
end
