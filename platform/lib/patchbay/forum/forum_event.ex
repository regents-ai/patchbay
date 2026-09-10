defmodule Patchbay.Forum.ForumEvent do
  @moduledoc """
  A durable record that something on the board happened — a reply landed, a
  question was asked, a solution was named. Written in the same transaction
  as the content it announces, so a published reply can never exist without
  the event waiting on it.

  `fanned_out_at` is nil until the notification worker has delivered the
  event to every matching subscription. The worker finds work by that flag,
  never by a position in the stream, so an event committed after a run is
  never stranded behind it.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_events")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes one durable event alongside the content it announces.")
      accept([:kind, :thread_id, :site_id, :tool_id, :actor_principal])
    end

    update :mark_fanned_out do
      description("The notification worker's receipt that it delivered this event.")
      change(set_attribute(:fanned_out_at, &DateTime.utc_now/0))
    end

    read :awaiting_fanout do
      description("Events the notification worker has not delivered yet, oldest first.")
      filter(expr(is_nil(fanned_out_at)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end
  end

  policies do
    # There is no public way in. Content actions write events internally, and
    # the fan-out worker is the only reader; both skip authorization.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :atom do
      allow_nil?(false)
      constraints(one_of: [:thread_posted, :reply_posted, :solution_marked])
    end

    attribute(:thread_id, :uuid, allow_nil?: false)
    attribute(:site_id, :uuid, allow_nil?: false)
    attribute(:tool_id, :uuid, allow_nil?: true)

    # Who did it, so the actor is never notified of their own work.
    attribute(:actor_principal, :string, allow_nil?: true, public?: true)

    attribute(:fanned_out_at, :utc_datetime_usec, allow_nil?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    # The thread and site the event happened on, for whoever reads it back.
    belongs_to(:thread, Patchbay.Forum.Report,
      source_attribute: :thread_id,
      define_attribute?: false,
      public?: true
    )

    belongs_to(:site, Patchbay.Forum.Site,
      source_attribute: :site_id,
      define_attribute?: false,
      public?: true
    )
  end
end
