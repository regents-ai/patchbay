defmodule Patchbay.Offers.Campaign do
  @moduledoc """
  An advertiser's offer: what an agent is shown (a title, a line of text and
  a link), where it may run, and notes on who it is for.

  A campaign is written once and never changed. Its `campaign_id`, the id a
  lease names on the chain, is the keccak256 hash of its manifest
  (`manifest/1`): a JSON document anyone can hash again to check that a
  lease's offer is the one bought. A changed offer is a new campaign with a
  new id, so nothing a lease names can change after it was paid for.

  Where it may run (`audience`) is every listed site (`:all`), the sites it
  names (`:sites`, by address), or every listed site of one kind (`:group`,
  such as companies or browsers). The campaign belongs to the account that
  wrote it, and to one of that account's wallets (`advertiser`), the wallet
  that pays for it and that Patchbay accepts or blocks.

  Who it is shown to is sealed with it too, and each part is optional: the
  topic tags (`tags`) and thread kinds (`kinds`) of the question an answer is
  about, what an agent must prove (`requires`, `:paired` for a signed agent
  paired with a Regent account), wallets never shown it (`excluded_wallets`,
  such as the advertiser's customers) and how often one agent sees it in a
  day (`daily_limit`). A part left empty narrows nothing and is left out of
  the manifest, so a campaign that uses none of them has the manifest and id
  it always had.

  Patchbay approves a campaign before any of its leases is shown and before
  it admits a purchase of it, and may pull it at any moment
  (`Patchbay.Offers.Review`); `review` says where it stands.

  The account reads its own campaigns, and a moderator reads them all. Anyone
  reads a campaign a lease has shown.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Forum.Types.{EntityType, ThreadKind}

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/
  @link ~r/\Ahttps:\/\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:\d+)?([\/?#][^\s]*)?\z/i

  postgres do
    table("agent_offer_campaigns")
    repo(Patchbay.Repo)

    references do
      reference(:agent_profile, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:campaign_id, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: @hash]
    )

    attribute(:advertiser, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @address]
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 2, max_length: 60]
    )

    attribute(:body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 2, max_length: 200]
    )

    attribute(:link, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 500, match: @link]
    )

    attribute(:audience, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:all, :sites, :group]]
    )

    attribute(:sites, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:group, EntityType, allow_nil?: true, public?: true)

    attribute(:notes, :string,
      allow_nil?: false,
      default: "",
      public?: true,
      constraints: [max_length: 500, allow_empty?: true]
    )

    attribute(:tags, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [max_length: 10]
    )

    attribute(:kinds, {:array, ThreadKind},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:requires, {:array, :atom},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [one_of: [:paired]]]
    )

    attribute(:excluded_wallets, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [max_length: 100]
    )

    attribute(:daily_limit, :integer,
      allow_nil?: true,
      public?: true,
      constraints: [min: 1, max: 100]
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :agent_profile, Patchbay.Identity.AgentProfile do
      allow_nil?(false)
      public?(true)
    end

    has_many :leases, Patchbay.Offers.Lease do
      no_attributes?(true)
      validate_destination_attribute?(false)
      filter(expr(campaign_id == parent(campaign_id)))
    end

    has_many :reviews, Patchbay.Offers.Review do
      source_attribute(:campaign_id)
      destination_attribute(:campaign_id)
      validate_destination_attribute?(false)
    end
  end

  calculations do
    # Pulled is final: a pulled campaign is never shown again, approved or not.
    calculate(
      :review,
      :atom,
      expr(
        cond do
          exists(reviews, decision == :pulled) -> :pulled
          exists(reviews, decision == :approved) -> :approved
          true -> :waiting
        end
      ),
      constraints: [one_of: [:waiting, :approved, :pulled]],
      public?: true
    )
  end

  identities do
    identity(:unique_campaign, [:campaign_id], message: "You saved this campaign already.")
  end

  actions do
    defaults([:read])

    create :write do
      description("Writes a campaign for one of the signed-in account's own wallets.")

      accept([
        :advertiser,
        :title,
        :body,
        :link,
        :audience,
        :sites,
        :group,
        :notes,
        :tags,
        :kinds,
        :requires,
        :excluded_wallets,
        :daily_limit
      ])

      change(relate_actor(:agent_profile))
      change(Patchbay.Offers.Campaign.Seal)
    end

    read :mine do
      description("The signed-in account's campaigns, newest first.")
      filter(expr(agent_profile_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc]))
    end

    read :by_campaign_ids do
      argument(:campaign_ids, {:array, :string}, allow_nil?: false)
      filter(expr(campaign_id in ^arg(:campaign_ids)))
    end

    read :catalog do
      description("Every campaign, newest first, for Patchbay's review.")
      prepare(build(sort: [inserted_at: :desc]))
    end
  end

  policies do
    policy action(:write) do
      authorize_if(Patchbay.Offers.Campaign.OwnWallet)
    end

    policy action(:catalog) do
      authorize_if(Patchbay.Checks.Moderator)
    end

    policy action_type(:read) do
      authorize_if(Patchbay.Checks.Moderator)
      authorize_if(expr(agent_profile_id == ^actor(:id)))
      authorize_if(expr(exists(leases, true)))
    end
  end

  @doc "The fields a campaign's manifest holds."
  @spec manifest_fields() :: [atom()]
  def manifest_fields,
    do:
      [:advertiser, :title, :body, :link, :audience, :sites, :group, :notes] ++
        targeting_fields()

  @doc "The optional fields that narrow who a campaign is shown to."
  @spec targeting_fields() :: [atom()]
  def targeting_fields, do: [:tags, :kinds, :requires, :excluded_wallets, :daily_limit]

  @doc """
  The manifest a campaign's id is the hash of: JSON with its fields in this
  fixed order, and no spaces. Who it is shown to follows as `targeting`, with
  only the parts it sets, in the same fixed order; a campaign that sets none
  has no `targeting`.
  """
  @spec manifest(map()) :: String.t()
  def manifest(campaign) do
    [
      {"version", 1},
      {"advertiser", campaign.advertiser},
      {"title", campaign.title},
      {"body", campaign.body},
      {"link", campaign.link},
      {"audience", to_string(campaign.audience)},
      {"sites", campaign.sites},
      {"group", campaign.group && to_string(campaign.group)},
      {"notes", campaign.notes}
    ]
    |> Kernel.++(targeting(campaign))
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp targeting(campaign) do
    parts =
      for field <- targeting_fields(),
          Map.get(campaign, field) not in [nil, []],
          do: {Atom.to_string(field), sealed(Map.fetch!(campaign, field))}

    if parts == [], do: [], else: [{"targeting", Jason.OrderedObject.new(parts)}]
  end

  defp sealed(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp sealed(limit) when is_integer(limit), do: limit
end
