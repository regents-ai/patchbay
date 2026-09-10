defmodule Patchbay.Forum.ModerationAction do
  @moduledoc """
  The record of a moderation decision: who made it, what it touched, why, and
  when. Rows are written alongside the change they describe and are never
  updated or deleted — a decision that changes is a new row, not an edit.

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
    # There is no public way in. Forum.moderate/4 is the only writer and the
    # moderation page the only reader; both skip authorization deliberately.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    # What the decision touched: a thread or a reply, and its id.
    attribute(:subject_kind, :atom, allow_nil?: false, constraints: [one_of: [:thread, :reply]])
    attribute(:subject_id, :uuid, allow_nil?: false)

    attribute(:action, :atom,
      allow_nil?: false,
      constraints: [one_of: [:quarantine, :publish, :redact]]
    )

    attribute(:reason, :string, allow_nil?: false, constraints: [max_length: 500])
    attribute(:actor_profile_id, :uuid, allow_nil?: false)

    create_timestamp(:inserted_at, public?: true)
  end
end
