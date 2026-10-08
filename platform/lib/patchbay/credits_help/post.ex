defmodule Patchbay.CreditsHelp.Post do
  @moduledoc """
  One question someone asked the Regents team about their Credits. Only its
  author and Patchbay's moderators can read it.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.CreditsHelp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("credits_help_posts")
    repo(Patchbay.Repo)

    references do
      reference(:author, index?: true)
    end
  end

  actions do
    defaults([:read])

    create :ask do
      description("The actor asks the Regents team about their Credits.")
      accept([:title, :body])
      change(set_attribute(:author_profile_id, actor(:id)))
    end

    read :newest do
      description("""
      The posts the actor may read, newest first: their own, or every post for
      a moderator.
      """)

      prepare(build(sort: [inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 20, max_page_size: 50)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Patchbay.CreditsHelp.Checks.Admin)
      authorize_if(expr(author_profile_id == ^actor(:id)))
    end

    # A post is asked under a name, so there has to be one.
    policy action(:ask) do
      authorize_if(actor_present())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 140)
    end

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 5000)
    end

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: false,
      public?: true
    )

    has_many(:answers, Patchbay.CreditsHelp.Answer, public?: true)
  end

  aggregates do
    count(:answer_count, :answers, public?: true)
    max(:last_answered_at, :answers, :inserted_at, public?: true)
  end
end
