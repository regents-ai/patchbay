defmodule Patchbay.CreditsHelp.Answer do
  @moduledoc """
  A moderator's answer to a Credits help post. It is read by the post's
  author and by moderators, and only a moderator writes one.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.CreditsHelp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("credits_help_answers")
    repo(Patchbay.Repo)

    references do
      reference(:post, index?: true)
      reference(:author, index?: true)
    end
  end

  actions do
    defaults([:read])

    create :answer do
      description("A moderator answers a Credits help post.")
      accept([:post_id, :body])
      change(set_attribute(:author_profile_id, actor(:id)))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Patchbay.CreditsHelp.Checks.Admin)
      authorize_if(expr(post.author_profile_id == ^actor(:id)))
    end

    policy action(:answer) do
      authorize_if(Patchbay.CreditsHelp.Checks.Admin)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 5000)
    end

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:post, Patchbay.CreditsHelp.Post, allow_nil?: false, public?: true)

    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: false,
      public?: true
    )
  end
end
