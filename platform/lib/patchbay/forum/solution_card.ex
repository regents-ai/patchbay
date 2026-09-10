defmodule Patchbay.Forum.SolutionCard do
  @moduledoc """
  The reusable, source-linked form of an answer a thread produced: what the
  problem was, who it applies to, the proposed steps, and the caveats — with a
  digest of the reply it was distilled from so the card is pinned to its
  source, and a status so a redacted source takes its card down with it.

  Cards are derived records: the asker's selection of a reply creates one as
  a summary, always attributed as a summary, never as independently verified.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_solution_cards")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read])

    create :derive do
      description("""
      Distils a named solution into a card. Written by mark_solution; the
      selection that made it is the asker's approval, so it publishes at once.
      """)

      accept([
        :thread_id,
        :source_reply_id,
        :problem_summary,
        :applicability,
        :proposed_steps,
        :caveats,
        :source_digest,
        :source_author_profile_id,
        :reviewed_by_profile_id
      ])

      change(set_attribute(:status, :published))
      change(set_attribute(:reviewed_at, &DateTime.utc_now/0))
    end

    update :invalidate do
      description("""
      The source of this card was taken out of view; the card may not stand
      for it any more. Applied to the card's own query, once.
      """)

      filter(expr(status != :invalidated))
      change(set_attribute(:status, :invalidated))
    end

    read :for_thread do
      description("The published cards a thread produced.")
      argument(:thread_id, :uuid, allow_nil?: false)
      filter(expr(thread_id == ^arg(:thread_id) and status == :published))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end
  end

  policies do
    # Reads are public — a published card is public content. Deriving and
    # invalidating are internal writes made by the selection and moderation
    # flows, which name their own callers and skip authorization there.
    policy action_type(:read) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:problem_summary, :string, allow_nil?: false, public?: true)
    attribute(:applicability, :string, allow_nil?: true, public?: true)
    attribute(:proposed_steps, :string, allow_nil?: false, public?: true)
    attribute(:caveats, :string, allow_nil?: true, public?: true)

    # What the card was distilled from, pinned by digest so a changed or
    # removed source cannot silently keep its card.
    attribute(:source_digest, :string, allow_nil?: false, public?: true)
    attribute(:source_author_profile_id, :uuid, allow_nil?: true, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:published, :invalidated])
      default(:published)
      public?(true)
    end

    attribute(:reviewed_by_profile_id, :uuid, allow_nil?: true, public?: true)
    attribute(:reviewed_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at, public?: true)
  end

  relationships do
    belongs_to(:thread, Patchbay.Forum.Report, allow_nil?: false, public?: true)
    belongs_to(:source_reply, Patchbay.Forum.Reply, allow_nil?: false, public?: true)
  end
end
