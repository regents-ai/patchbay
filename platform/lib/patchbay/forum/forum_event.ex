defmodule Patchbay.Forum.ForumEvent do
  @moduledoc """
  A durable record that something on the board happened — a reply landed, a
  question was asked, a solution was named. Written in the same transaction
  as the content it announces, so a published reply can never exist without
  the event waiting on it.

  `seq` is the event's place in the stream, and it is the order events
  *committed* in, not the order they were started in: the number is taken
  under a lock that is held until the transaction commits, so no event can
  ever appear with a lower number after one with a higher number is already
  visible. A reader holding "everything up to N" therefore misses nothing by
  asking for "after N".

  `fanned_out_at` is nil until the notification worker has delivered the
  event to every matching subscription for the people's Inbox page. The
  worker finds work by that flag, never by a position in the stream.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_events")
    repo(Patchbay.Repo)

    # An event names its thread and site rather than pointing at them: the
    # table has no foreign keys, and the generator is told so, or it would
    # try to add them on every run.
    references do
      reference(:thread, ignore?: true)
      reference(:site, ignore?: true)
    end
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes one durable event alongside the content it announces.")
      accept([:kind, :thread_id, :site_id, :tool_id, :resource_id, :actor_principal])
      change(Patchbay.Forum.Changes.OrderAtCommit)
    end

    update :mark_fanned_out do
      description("The notification worker's receipt that it delivered this event.")
      change(set_attribute(:fanned_out_at, &DateTime.utc_now/0))
    end

    read :awaiting_fanout do
      description("Events the notification worker has not delivered yet, oldest first.")
      filter(expr(is_nil(fanned_out_at)))
      prepare(build(sort: [seq: :asc]))
    end
  end

  policies do
    # There is no public way in. Content actions write events internally, and
    # the feed and the fan-out worker read them under queries that already
    # confine what they return; all of them skip authorization.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    # The event's place in the committed stream; see the moduledoc.
    attribute(:seq, :integer, allow_nil?: false, generated?: true, public?: true)

    attribute :kind, :atom do
      allow_nil?(false)
      constraints(one_of: [:thread_posted, :reply_posted, :solution_marked])
    end

    attribute(:thread_id, :uuid, allow_nil?: false)
    attribute(:site_id, :uuid, allow_nil?: false)
    attribute(:tool_id, :uuid, allow_nil?: true)

    # What the event is about: the thread itself when one was posted, the
    # reply when one was posted or named the solution.
    attribute(:resource_id, :uuid, allow_nil?: false, public?: true)

    # Who did it, so the actor is never told of their own work.
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

  identities do
    identity(:seq, [:seq], eager_check?: false)
  end
end
