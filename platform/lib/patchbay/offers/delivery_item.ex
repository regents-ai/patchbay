defmodule Patchbay.Offers.DeliveryItem do
  @moduledoc """
  One Offer returned in a response: the position it held, whether it was the
  site's own slot or Global's of the same number, and the exact placement
  and wording returned.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_delivery_items")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:position, "offer_delivery_items_position_range",
        check: "position BETWEEN 1 AND 3",
        message: "a position is 1, 2 or 3"
      )
    end

    custom_indexes do
      index([:placement_id, :inserted_at])
    end

    references do
      reference(:delivery, on_delete: :restrict)
      reference(:placement, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:position, :integer, allow_nil?: false, public?: true)

    attribute(:scope, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:site, :global]]
    )

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:one_per_position, [:delivery_id, :position])
  end

  relationships do
    belongs_to(:delivery, Patchbay.Offers.Delivery, allow_nil?: false, public?: true)
    belongs_to(:placement, Patchbay.Offers.Placement, allow_nil?: false, public?: true)
    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :record do
      accept([:delivery_id, :position, :scope, :placement_id, :version_id])
    end
  end

  policies do
    # Written with its delivery, read only for metrics.
    policy always() do
      forbid_if(always())
    end
  end
end
