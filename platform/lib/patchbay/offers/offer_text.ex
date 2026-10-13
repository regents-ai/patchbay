defmodule Patchbay.Offers.OfferText do
  @moduledoc """
  One row for each distinct Offer wording, by the SHA-256 of its normalized
  text, whoever saved it and under whatever name.

  It is where a block lives. Saving a wording takes this row's lock
  (`:claim`) and refuses a blocked text; blocking takes the same lock, so a
  save and a block of the same words never cross: the save either commits
  first and its version is blocked with the rest, or waits and is refused.
  A block outlasts every Offer that used the words, including deleted ones.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_texts")
    repo(Patchbay.Repo)
  end

  attributes do
    attribute(:text_sha256, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    )

    attribute(:blocked_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:block_reason, :string,
      allow_nil?: true,
      constraints: [max_length: 500]
    )

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    has_many :versions, Patchbay.Offers.CreativeVersion do
      source_attribute(:text_sha256)
      destination_attribute(:text_sha256)
    end
  end

  actions do
    defaults([:read])

    create :claim do
      description("""
      Keeps the row for a wording being saved and locks it until the save
      commits. A row already there is locked and returned as it stands.
      """)

      accept([:text_sha256])
      upsert?(true)
      # Nothing changes on a row already there; the conflict's update only
      # takes its lock and returns it, block and all.
      upsert_fields([])
    end

    update :block do
      description("""
      Blocks these words everywhere, at once: every Offer that has them stops
      showing, and they can never be saved again. Records who did, why, and
      the wording that was pressed.
      """)

      accept([])
      require_atomic?(false)
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 500])
      argument(:idempotency_key, :string, allow_nil?: false, constraints: [max_length: 200])
      argument(:version_id, :uuid, allow_nil?: false)

      validate(attribute_equals(:blocked_at, nil), message: "is already blocked")
      validate(Patchbay.Offers.Validations.WordingOfText)
      change(set_attribute(:blocked_at, &DateTime.utc_now/0))
      change(set_attribute(:block_reason, arg(:reason)))
      change({Patchbay.Offers.Changes.RecordModeration, kind: :block_version})
      change(Patchbay.Offers.Changes.LogTurnDown)
    end
  end

  policies do
    # An advertiser reads the row of words they saved, to see a block on
    # their own Offer; saving and the admin page read it inside Patchbay's
    # own actions.
    policy action_type(:read) do
      authorize_if(expr(exists(versions, creative.owner_profile_id == ^actor(:id))))
    end

    # Taken only inside a save, whose own policy has said who may save.
    policy action(:claim) do
      forbid_if(always())
    end

    policy action(:block) do
      authorize_if(Patchbay.Checks.Moderator)
    end
  end
end
