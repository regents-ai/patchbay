defmodule Patchbay.Offers.Market do
  @moduledoc """
  Where Offers are placed: the board about one site, or Global.

  A site market belongs to one canonical `Patchbay.Forum.Site`, never to a
  URL, so a renamed or aliased site keeps its market. There is exactly one
  Global market, made by the migration that made this table, and at most
  one market per site, made the first time it is needed. Every market has
  exactly three slots, numbered 1 to 3, made with it.

  A site market may carry its own opening minimum, which replaces the
  default for that site. Global always uses the default minimum.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_markets")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:site_id, "offer_markets_scope_shape",
        check: "(scope = 'site') = (site_id IS NOT NULL)",
        message: "a site market names its site and Global names none"
      )

      check_constraint(:minimum_override_minor, "offer_markets_minimum_positive",
        check:
          "minimum_override_minor IS NULL OR (scope = 'site' AND minimum_override_minor > 0)",
        message: "only a site market may set its own minimum, and it must be positive"
      )
    end

    custom_indexes do
      # One Global market: every Global row has the same scope, so a unique
      # index on scope limited to Global allows exactly one.
      index([:scope], unique: true, where: "scope = 'global'", name: "offer_markets_one_global")
    end

    references do
      # A site with Offer history is never deleted out from under it.
      reference(:site, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:scope, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:site, :global]]
    )

    attribute(:minimum_override_minor, :integer, allow_nil?: true, public?: true)

    # Raised whenever this market's rules change, and frozen into each bid.
    attribute(:policy_revision, :integer, allow_nil?: false, default: 1, public?: true)

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_site, [:site_id])
  end

  relationships do
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: true, public?: true)

    has_many :slots, Patchbay.Offers.Slot do
      sort(number: :asc)
    end
  end

  actions do
    defaults([:read])

    read :global do
      description("The Global market.")
      get?(true)
      filter(expr(scope == :global))
    end

    create :open_for_site do
      description("Opens a site's market with its three slots, or returns the one it has.")
      accept([])
      argument(:site_id, :uuid, allow_nil?: false)
      upsert?(true)
      upsert_identity(:unique_site)
      # A second open of the same site writes nothing new and hands back the row.
      upsert_fields([:site_id])
      change(set_attribute(:scope, :site))
      change(set_attribute(:site_id, arg(:site_id)))
      change(Patchbay.Offers.Changes.OpenSlots)
    end

    update :set_minimum do
      description("Sets or clears the site's own opening minimum.")
      accept([:minimum_override_minor])
      require_atomic?(false)
      change(atomic_update(:policy_revision, expr(policy_revision + 1)))
    end
  end

  policies do
    # Markets are public. Opening one and setting its minimum happen only
    # inside Patchbay's own actions, which skip authorization deliberately.
    policy action_type(:read) do
      authorize_if(always())
    end
  end
end
