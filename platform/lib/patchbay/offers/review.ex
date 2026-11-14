defmodule Patchbay.Offers.Review do
  @moduledoc """
  Patchbay's decision on a campaign, by its id: approved, so its leases are
  shown and its purchases admitted, or pulled, so it is shown nowhere from
  that moment and never admitted again. Each decision is made at most once
  for a campaign and never changed or removed; pulled outweighs approved, so
  a pulled campaign stays pulled (`Patchbay.Offers.Campaign`'s `review`).

  Pulling stops the showing at once. The money of a lease already paid for
  follows the market's own path, which only the publisher's wallet can take:
  terminate the placement, then settle each of its slots, which refunds every
  live lease for the time it had left (`contracts/README.md`). The operator
  page names those steps; nothing here signs them.

  Only a moderator decides (`Patchbay.Checks.Moderator`). Whether a campaign
  is approved is no secret, so anyone reads the decisions; the operator page
  alone shows their reasons.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @hash ~r/\A0x[0-9a-f]{64}\z/

  postgres do
    table("agent_offer_reviews")
    repo(Patchbay.Repo)
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)
    publish_all(:create, ["offers"], transform: fn _notification -> :offers_changed end)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:campaign_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @hash]
    )

    attribute(:decision, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:approved, :pulled]]
    )

    attribute(:reason, :string,
      allow_nil?: false,
      default: "",
      constraints: [max_length: 500, allow_empty?: true]
    )

    attribute(:moderator_id, :uuid, allow_nil?: false)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:once_each, [:campaign_id, :decision])
  end

  # Deciding the same again keeps the decision already made, as it stands.
  actions do
    defaults([:read])

    create :approve do
      description("Approves a campaign, so its leases are shown and its purchases admitted.")
      accept([:campaign_id, :reason])
      change(set_attribute(:decision, :approved))
      change(set_attribute(:moderator_id, actor(:id)))
      upsert?(true)
      upsert_identity(:once_each)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end

    create :pull do
      description("Pulls a campaign: it is shown nowhere from now on.")
      accept([:campaign_id, :reason])
      change(set_attribute(:decision, :pulled))
      change(set_attribute(:moderator_id, actor(:id)))
      upsert?(true)
      upsert_identity(:once_each)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(Patchbay.Checks.Moderator)
    end
  end
end
