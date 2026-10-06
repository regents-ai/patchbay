defmodule Patchbay.Offers.ModerationAction do
  @moduledoc """
  A moderator's decision about an Offer, kept for good.

    * `:remove_placement` - ended one exact placement for improper use, with
      no refund, and promoted the committed next leader if it could start;
    * `:block_version` - stopped one wording showing anywhere, at once;
    * `:dismiss_report` and `:confirm_report` - closed an agent's report;
    * `:allow_version` and `:refuse_version` - decided a screening that
      needed a person.

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
      index([:report_id])
      index([:review_id])
    end

    references do
      reference(:moderator, on_delete: :restrict)
      reference(:placement, on_delete: :restrict)
      reference(:version, on_delete: :restrict)
      reference(:promoted_placement, on_delete: :restrict)
      reference(:report, on_delete: :restrict)
      reference(:review, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :remove_placement,
          :block_version,
          :dismiss_report,
          :confirm_report,
          :allow_version,
          :refuse_version
        ]
      ]
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

    # For a dismissed or confirmed report: the report decided.
    belongs_to(:report, Patchbay.Offers.OfferReport, allow_nil?: true, public?: true)

    # For an allowed or refused wording: the screening decided.
    belongs_to(:review, Patchbay.Offers.Review, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :record do
      description("Records a moderator's decision, written with the change it decided.")

      accept([
        :kind,
        :reason,
        :idempotency_key,
        :placement_id,
        :version_id,
        :report_id,
        :review_id,
        :expected_generation,
        :outcome,
        :consumed_minor,
        :forfeited_minor,
        :promoted_placement_id,
        :policy_revision
      ])

      change(relate_actor(:moderator))
    end

    action :remove_placement, :struct do
      description("""
      Removes one exact placement for improper use. Nothing goes back to its
      owner: the time already shown counts as used and the rest is
      forfeited. The slot's waiting next-period leader starts at once if it
      can. Repeating the request answers with the first decision, and a
      placement that had already ended is never removed in its successor's
      place.
      """)

      constraints(instance_of: __MODULE__)
      transaction?(true)

      argument(:placement_id, :uuid, allow_nil?: false)
      argument(:expected_generation, :integer, allow_nil?: false)

      argument(:reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 2000]
      )

      # The moderator's explicit agreement that the owner gets nothing back.
      argument(:no_refund, :boolean, allow_nil?: false)

      argument(:idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]
      )

      run(fn input, context ->
        Patchbay.Offers.Removal.remove(input.arguments, context.actor)
      end)
    end
  end

  policies do
    policy action(:remove_placement) do
      authorize_if(Patchbay.Offers.Checks.Moderator)
    end

    # Recorded only with the decision it records, whose own policy says who
    # may make it; read on the moderator page only, which checks the
    # moderator itself. Both skip authorization deliberately.
    policy action([:record, :read]) do
      forbid_if(always())
    end
  end
end
