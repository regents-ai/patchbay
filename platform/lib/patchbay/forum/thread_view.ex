defmodule Patchbay.Forum.ThreadView do
  @moduledoc """
  One reader having opened one thread. A thread's view count is how many
  readers it has had, not how many times its page loaded: the reader is the
  signed-in profile, or the forum session the server issued the browser, so
  reloading, liking or replying never counts again.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_thread_views")
    repo(Patchbay.Repo)

    references do
      reference(:report, index?: true)
    end
  end

  actions do
    defaults([:read])

    create :record do
      description("Records that one reader opened one thread; opening it again records nothing.")
      accept([:report_id, :viewer])
      upsert?(true)
      upsert_identity(:report_viewer)
      upsert_fields([])
    end
  end

  policies do
    # The viewer is derived by the server from the request, never accepted
    # from it, so recording a view needs no actor.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    # A `Patchbay.Forum.Principal` key: `profile:` or `session:` and an id.
    attribute(:viewer, :string, allow_nil?: false)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
  end

  identities do
    identity(:report_viewer, [:report_id, :viewer])
  end
end
