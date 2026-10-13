defmodule Patchbay.Forum.PostCheck do
  @moduledoc """
  One reading of a post or reply before it was published: what Jev found, how
  sure it was, and whether the post was turned away for it.

  The reading is kept under the person the post would have gone out for, so
  every agent a person has paired is counted with them. It keeps a digest of
  the words. A post that was turned away also keeps the words Jev was shown,
  so a moderator can read what was refused and say whether it was right to
  (`Patchbay.Forum.PostReview`); they are published nowhere, and
  `Patchbay.Forum.PostCheckPruner` forgets them after a month. A moderator
  may keep a short cut of them as one of Jev's examples, which stays until a
  moderator takes it out.

  A post turned away counts toward its person's pause unless a moderator
  ruled it wrong to block or lifted the pause it led to (`counts?/1`).

  Every write is Patchbay's own and says so by skipping authorization:
  `Patchbay.Forum.PostingCheck` records the reading, and the moderators'
  page rules on it through `Patchbay.Forum.PostReview`.
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
      # The moderators' list of posts turned away, newest first.
      index([:inserted_at], where: "rejected")
      # Jev's examples, read with every post.
      index([:inserted_at],
        where: "example IS NOT NULL",
        name: "forum_post_checks_examples_index"
      )
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

    # What Jev was shown, kept only for a post turned away.
    attribute(:shown, :map, allow_nil?: true, public?: true)
    # A moderator's word on a post turned away: right to block, or wrong to.
    attribute(:ruling, :atom,
      allow_nil?: true,
      public?: true,
      constraints: [one_of: [:right, :wrong]]
    )

    # When a moderator lifted the pause this post turned away counted toward.
    attribute(:lifted_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    # The cut of its words Jev reads as an example, when a moderator chose it.
    attribute(:example, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 400, trim?: false]
    )

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
        :input_sha256,
        :shown
      ])
    end

    update :rule do
      description("""
      A moderator's word on a post turned away, or none to take it back. An
      example stands for the ruling it was chosen under, so it goes with it.
      """)

      accept([:ruling])
      change(set_attribute(:example, nil))
    end

    update :set_example do
      description("Makes a cut of the words one of Jev's examples, or takes it out.")
      accept([:example])
    end

    update :lift do
      description("Stops a post turned away counting toward its person's pause.")
      change(set_attribute(:lifted_at, &DateTime.utc_now/0))
    end

    update :forget do
      description("Forgets the words of a post turned away.")
      change(set_attribute(:shown, nil))
    end

    read :for_profile_since do
      description("One person's readings after a moment, oldest first.")
      argument(:profile_id, :uuid, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      filter(expr(profile_id == ^arg(:profile_id) and inserted_at > ^arg(:since)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    read :turned_away do
      description("The newest posts turned away, for the moderators' page.")
      filter(expr(rejected))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :turned_away_since do
      description("Posts turned away for these people after a moment, oldest first.")
      argument(:profile_ids, {:array, :uuid}, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      filter(expr(rejected and profile_id in ^arg(:profile_ids) and inserted_at > ^arg(:since)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    read :examples do
      description("Jev's examples, newest first.")
      filter(expr(rejected and not is_nil(ruling) and not is_nil(example)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :words_kept_since do
      description("Posts turned away after a moment whose words are kept.")
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      filter(expr(rejected and not is_nil(shown) and inserted_at > ^arg(:since)))
    end

    read :forgettable do
      description("Posts turned away before a moment whose words are still kept.")
      argument(:before, :utc_datetime_usec, allow_nil?: false)
      filter(expr(rejected and not is_nil(shown) and inserted_at < ^arg(:before)))
    end
  end

  policies do
    # No visitor reads or writes these; Patchbay's own work skips this.
    policy always() do
      forbid_if(always())
    end
  end

  @doc """
  Whether a reading counts toward its person's pause: the post was turned
  away, and no moderator ruled that wrong or lifted the pause since.
  """
  @spec counts?(t()) :: boolean()
  def counts?(%{rejected: true, ruling: ruling, lifted_at: nil}) when ruling != :wrong, do: true
  def counts?(_check), do: false
end
