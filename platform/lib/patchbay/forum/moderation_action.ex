defmodule Patchbay.Forum.ModerationAction do
  @moduledoc """
  The record of a moderation decision: who made it, what it touched, why, and
  when. Rows are written alongside the change they describe and are never
  updated or deleted — a decision that changes is a new row, not an edit.
  A decision is about a thread or a reply on the board, about a post that
  was turned away before it was published, or about a person's pause.

  Nothing public reads these; they exist so a decision can be accounted for
  later. They carry ids and reasons, never the content that was redacted.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_moderation_actions")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes one audit row for a moderation decision already made.")
      accept([:subject_kind, :subject_id, :action, :reason, :actor_profile_id])
    end
  end

  policies do
    # There is no public way in. Forum.moderate/4 and Forum.PostReview are the
    # only writers and the moderation page the only reader; all skip
    # authorization deliberately.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    # What the decision touched and its id: a thread, a reply, the reading of
    # a post that was turned away, or a person.
    attribute(:subject_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:thread, :reply, :post_check, :person]]
    )

    attribute(:subject_id, :uuid, allow_nil?: false)

    attribute(:action, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :quarantine,
          :publish,
          :redact,
          :right_to_block,
          :wrong_to_block,
          :ruling_withdrawn,
          :example_added,
          :example_removed,
          :pause_lifted
        ]
      ]
    )

    attribute(:reason, :string, allow_nil?: false, constraints: [max_length: 500])
    attribute(:actor_profile_id, :uuid, allow_nil?: false)

    create_timestamp(:inserted_at, public?: true)
  end
end
