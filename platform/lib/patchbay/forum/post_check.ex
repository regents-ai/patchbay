defmodule Patchbay.Forum.PostCheck do
  @moduledoc """
  One reading of a post or reply before it was published: what Jev found, how
  sure it was, and whether the post was turned away for it.

  The reading is kept under the person the post would have gone out for, so
  every agent a person has paired is counted with them. It keeps a digest of
  the words and never the words themselves: a post that was turned away is
  published nowhere, here included.

  Every write is Patchbay's own and says so by skipping authorization;
  `Patchbay.Forum.PostingCheck` is the only writer.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Forum.Types.PostFinding

  postgres do
    table("forum_post_checks")
    repo(Patchbay.Repo)

    custom_indexes do
      # A person's recent readings: their rejects today and their checks this hour.
      index([:profile_id, :inserted_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    # The person the post would have been published for.
    attribute(:profile_id, :uuid, allow_nil?: false, public?: true)
    # The paired agent that sent it, when one did.
    attribute(:acting_agent_id, :uuid, allow_nil?: true, public?: true)

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:report, :reply]]
    )

    attribute(:finding, PostFinding, allow_nil?: false, public?: true)
    attribute(:confidence, :float, allow_nil?: false, public?: true)
    attribute(:rejected, :boolean, allow_nil?: false, public?: true)
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:input_sha256, :string, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :record do
      description("What Jev found in one post, written once it has answered.")

      accept([
        :profile_id,
        :acting_agent_id,
        :kind,
        :finding,
        :confidence,
        :rejected,
        :model,
        :input_sha256
      ])
    end

    read :for_profile_since do
      description("One person's readings after a moment, oldest first.")
      argument(:profile_id, :uuid, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      filter(expr(profile_id == ^arg(:profile_id) and inserted_at > ^arg(:since)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end
  end

  policies do
    # No visitor reads or writes these; Patchbay's own work skips this.
    policy always() do
      forbid_if(always())
    end
  end
end
