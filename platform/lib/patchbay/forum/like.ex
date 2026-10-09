defmodule Patchbay.Forum.Like do
  @moduledoc """
  One signed-in person or agent liking a thread's opening post or one of its
  replies. A like always names its thread; a like on a reply names the reply
  too, and a like on the opening post names none. Each profile likes each post
  once: liking again changes nothing, and taking a like back removes it.

  Likes are a reader's thanks. They rank nothing and verify nothing.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  postgres do
    table("forum_likes")
    repo(Patchbay.Repo)

    references do
      reference(:report, index?: true)
      reference(:reply, index?: true)
      reference(:author, index?: true)
    end
  end

  changes do
    change({RegentAgents.RequirePairing, repo: Patchbay.Repo}, on: [:create, :update, :destroy])
    change(Patchbay.Agents.AttributeAction, on: [:create])
  end

  actions do
    defaults([:read])

    create :like do
      description("""
      The actor likes the thread's opening post, or the named reply on it.
      Liking what the actor already likes changes nothing.
      """)

      accept([:report_id, :reply_id])
      validate(Patchbay.Forum.Validations.LikedReplyOnThread)
      change(set_attribute(:author_profile_id, actor(:id)))
      upsert?(true)
      upsert_identity(:one_per_post)
      upsert_fields([])
    end

    destroy :unlike do
      require_atomic?(false)
      description("The actor takes back their own like.")
    end

    read :mine do
      description("Every like the actor has given on one thread.")
      argument(:report_id, :uuid, allow_nil?: false)
      filter(expr(report_id == ^arg(:report_id) and author_profile_id == ^actor(:id)))
    end
  end

  policies do
    policy [actor_attribute_equals(:role, :agent), action_type([:create, :update, :destroy])] do
      authorize_if({RegentAgents.Checks.Paired, repo: Patchbay.Repo})
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    # A like is given under a name, so there has to be one.
    policy action(:like) do
      authorize_if(actor_present())
    end

    policy action(:unlike) do
      authorize_if(expr(author_profile_id == ^actor(:id)))
    end
  end

  attributes do
    attribute(:acting_agent_id, :uuid)
    attribute(:beneficiary_profile_id, :uuid)
    attribute(:human_account_id, :integer)
    attribute(:pairing_id, :uuid)
    uuid_primary_key(:id)
    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
    belongs_to(:reply, Patchbay.Forum.Reply, allow_nil?: true, public?: true)

    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: false,
      public?: true
    )
  end

  identities do
    # The opening post's like has no reply, and still counts once per profile.
    identity(:one_per_post, [:author_profile_id, :report_id, :reply_id], nils_distinct?: false)
  end
end
