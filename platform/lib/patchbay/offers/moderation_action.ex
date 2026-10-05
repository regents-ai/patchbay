defmodule Patchbay.Offers.ModerationAction do
  @moduledoc """
  A moderator's decision about an Offer, kept for good.

    * `:remove_placement` - ended one exact placement for improper use, with
      no refund, and promoted the committed next leader if it could start;
    * `:block_version` - stopped one wording showing anywhere, at once;
    * `:dismiss_report` and `:confirm_report` - closed an agent's report.

  Each carries the moderator's idempotency key, so repeating a request
  answers with the first decision and never acts on whatever came next.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_moderation_actions")
    repo(Patchbay.Repo)

    custom_indexes do
      index([:inserted_at])
      index([:placement_id])
      index([:version_id])
    end

    references do
      reference(:moderator, on_delete: :restrict)
      reference(:placement, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
      reference(:promoted_placement, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:remove_placement, :block_version, :dismiss_report, :confirm_report]]
    )

    attribute(:reason, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 2000]
    )

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 200]
    )

    # For a removal: the slot generation the moderator saw, and what became
    # of it. `:removed`, or `:already_ended` when the placement had run out
    # first and ordinary expiry applied instead.
    attribute(:expected_generation, :integer, allow_nil?: true, public?: true)

    attribute(:outcome, :atom,
      allow_nil?: true,
      public?: true,
      constraints: [one_of: [:removed, :already_ended]]
    )

    attribute(:consumed_minor, :integer, allow_nil?: true, public?: true)
    attribute(:forfeited_minor, :integer, allow_nil?: true, public?: true)

    attribute(:policy_revision, :integer, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_request, [:moderator_profile_id, :idempotency_key])
  end

  relationships do
    belongs_to(:moderator, Patchbay.Identity.AgentProfile,
      source_attribute: :moderator_profile_id,
      allow_nil?: false,
      public?: true
    )

    belongs_to(:placement, Patchbay.Offers.Placement, allow_nil?: true, public?: true)
    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: true, public?: true)

    # The next leader that started at once when a removal freed the slot.
    belongs_to(:promoted_placement, Patchbay.Offers.Placement, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    # Read on the moderator page only, which checks the moderator itself and
    # skips authorization deliberately.
    policy always() do
      forbid_if(always())
    end
  end
end
