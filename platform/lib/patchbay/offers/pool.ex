defmodule Patchbay.Offers.Pool do
  @moduledoc """
  A pool: a saved filter and a membership list over the one campaign catalog,
  owned by Patchbay as the publisher, such as Developer Tools or Approved
  Partners. A campaign is in a pool when it targets at least one of the
  pool's topic tags (any campaign, when the pool names none) and its wallet
  is one of the pool's members (any wallet Patchbay accepts, when the pool
  has none).

  A placement shows campaigns from the pools Patchbay chose for it
  (`Patchbay.Offers.PlacementPool`); a placement with none chosen shows from
  General, every campaign Patchbay accepts. A new pool is a row: no contract
  changes.

  Only a moderator reads, makes or removes pools; Patchbay's own serving
  reads them as the system.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table("agent_offer_pools")
    repo(Patchbay.Repo)
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)
    publish_all(:create, ["offers"], transform: fn _notification -> :offers_changed end)
    publish_all(:destroy, ["offers"], transform: fn _notification -> :offers_changed end)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 2, max_length: 40]
    )

    attribute(:tags, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [max_length: 20]
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    has_many :members, Patchbay.Offers.PoolMember do
      public?(true)
    end
  end

  identities do
    identity(:unique_name, [:name], message: "A pool has that name already.")
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name, :tags])
      validate(Patchbay.Offers.Pool.Tags)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :system))
      authorize_if(Patchbay.Checks.Moderator)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(Patchbay.Checks.Moderator)
    end
  end
end

defmodule Patchbay.Offers.Pool.Tags do
  @moduledoc "A pool's filter names topic tags as threads carry them."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    tags = Ash.Changeset.get_attribute(changeset, :tags) || []

    if Enum.all?(tags, &Patchbay.Forum.TopicTag.valid?/1),
      do: :ok,
      else: {:error, field: :tags, message: "use topic tags"}
  end
end
