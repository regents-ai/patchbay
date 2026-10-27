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

  `fanned_out_at` is nil until the event has been delivered to every
  matching subscription for the people's Inbox page. Recording an event
  queues its `:fan_out` job in the same transaction, so a committed event
  always has its job and a rolled-back one queues nothing. The trigger's
  minute sweep picks up any event still unfanned without a job, such as one
  written just before this job existed. A job that runs twice delivers
  nothing twice: a run that starts after another has finished finds the event
  fanned out and stops, one that overlaps it waits on the event's row lock,
  and notifications are unique per event and recipient either way. When the
  attempts run out, as for a bug or a row the fan-out cannot write,
  `:give_up_fan_out` stamps the event so the sweep stops taking it, and
  AshOban logs the last error.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    triggers do
      trigger :fan_out do
        action(:fan_out)
        where(expr(is_nil(fanned_out_at)))
        queue(:notifications)
        # Ten attempts with Oban's default backoff span about twenty minutes. A
        # database that is down for longer fails the give-up too, so the event
        # stays unfanned and the sweep queues it again once the database is back.
        max_attempts(10)
        on_error(:give_up_fan_out)
        worker_module_name(Patchbay.Forum.ForumEvent.Workers.FanOut)
        scheduler_module_name(Patchbay.Forum.ForumEvent.Schedulers.FanOut)
      end
    end
  end

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

      accept([
        :kind,
        :thread_id,
        :site_id,
        :tool_id,
        :resource_id,
        :actor_principal,
        :acting_agent_id,
        :beneficiary_profile_id,
        :human_account_id,
        :pairing_id
      ])

      change(Patchbay.Forum.Changes.OrderAtCommit)
      change(Patchbay.Forum.Changes.WakeEventDelivery)
      change(run_oban_trigger(:fan_out))
    end

    update :fan_out do
      description("""
      Delivers the event to every principal following its thread, site or
      tool, except whoever caused it, and marks it delivered in the same
      transaction. Run by the `:fan_out` trigger.
      """)

      require_atomic?(false)
      change(Patchbay.Forum.Changes.FanOutEvent)
      change(set_attribute(:fanned_out_at, &DateTime.utc_now/0))
    end

    update :give_up_fan_out do
      description("Fan-out ran out of attempts; the sweep stops taking the event.")
      require_atomic?(false)
      argument(:error, :term, allow_nil?: false)
      change(set_attribute(:fanned_out_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # There is no public way in. Content actions write events internally, the
    # feed reads them under queries that already confine what it returns, and
    # the fan-out job is internal bookkeeping; all of them skip authorization.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    attribute(:acting_agent_id, :uuid)
    attribute(:beneficiary_profile_id, :uuid)
    attribute(:human_account_id, :integer)
    attribute(:pairing_id, :uuid)
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
