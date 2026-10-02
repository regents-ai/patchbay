defmodule Patchbay.Forum.EventSubscription do
  @moduledoc """
  One MCP events subscription: a connection's request to have one kind of
  board event posted to its callback address as it happens.

  The id is derived from the owner, the event name, the filter and the
  callback address (`Regent.MCPEvents.subscription_id/4`), so subscribing
  again with the same four is a refresh of this row, never a second one, and
  nobody can name another owner's subscription.

  Delivery reads the committed event stream (`ForumEvent`) forward from
  `delivered_seq`, the last event the callback acknowledged. The `:deliver`
  trigger runs one Oban job per subscription at a time, queued when a board
  event lands, when the subscription starts or is refreshed, and by a sweep
  every minute. A failed event is retried by Oban with backoff and never
  stepped over: `delivered_seq` moves only when the callback acknowledges.
  When the attempts run out, the subscription stops where it was, and a
  refresh resumes it from the same event.

  The signing secrets are stored encrypted (`Patchbay.Forum.EventSecret`)
  and never leave the server except as webhook signatures.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  oban do
    triggers do
      trigger :deliver do
        action(:deliver)
        queue(:webhooks)
        max_attempts(8)
        on_error(:halt)
        # A callback that is down for a while is normal; Oban keeps each
        # attempt's error on the job, and only the last one is logged.
        log_errors?(false)
        # One job per subscription at a time is the lock; nothing else is held.
        lock_for_update?(false)

        # Active, unexpired, and behind an event of the kind it asked for.
        where(
          expr(
            active and expires_at > now() and
              exists(
                Patchbay.Forum.ForumEvent,
                seq > parent(delivered_seq) and
                  ((parent(name) == "reply_created" and kind == :reply_posted) or
                     (parent(name) == "solution_marked" and kind == :solution_marked))
              )
          )
        )

        worker_module_name(Patchbay.Forum.EventSubscription.Workers.Deliver)
        scheduler_module_name(Patchbay.Forum.EventSubscription.Schedulers.Deliver)
      end
    end
  end

  postgres do
    table("forum_event_subscriptions")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :subscribe do
      description("Starts a subscription whose callback has just answered its challenge.")

      accept([
        :id,
        :owner_id,
        :name,
        :arguments,
        :url,
        :secret_ciphertext,
        :expires_at,
        :verified_at,
        :delivered_seq
      ])

      change(run_oban_trigger(:deliver))
    end

    update :refresh do
      description("""
      Extends a subscription and resumes it, keeping its place in the stream.
      A stopped subscription starts again at the event it stopped on.
      """)

      require_atomic?(false)
      accept([:expires_at, :verified_at])
      argument(:secret_ciphertext, :string, allow_nil?: false, sensitive?: true)
      argument(:rotation_ends_at, :utc_datetime_usec, allow_nil?: false)

      change(set_attribute(:active, true))
      change(set_attribute(:last_error, nil))
      change(Patchbay.Forum.Changes.RotateEventSecret)
      change(run_oban_trigger(:deliver))
    end

    update :deliver do
      description("""
      Posts the events the subscriber is owed, in order, each outside any
      transaction. Run by the `:deliver` trigger; see `PatchbayWeb.MCP.EventDelivery`.
      """)

      transaction?(false)
      require_atomic?(false)
      manual(PatchbayWeb.MCP.EventDelivery)
    end

    update :advance do
      description("Moves the subscription's place to an event it was sent or need not receive.")
      accept([:delivered_seq])
      change(set_attribute(:last_error, nil))
    end

    update :halt do
      description("Delivery stopped; the owed event stays owed until a refresh.")
      require_atomic?(false)
      argument(:error, :term, allow_nil?: false)
      change(set_attribute(:active, false))
      change(Patchbay.Forum.Changes.RecordDeliveryError)
    end
  end

  policies do
    # There is no public way in. The MCP door subscribes for the connection's
    # own server-derived principal, and the delivery job reads and writes
    # internally; all of them skip authorization.
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    attribute :id, :string do
      primary_key?(true)
      allow_nil?(false)
      writable?(true)
    end

    attribute(:owner_id, :string, allow_nil?: false)

    attribute :name, :string do
      allow_nil?(false)
      constraints(match: ~r/\A(reply_created|solution_marked)\z/)
    end

    attribute(:arguments, :map, allow_nil?: false)
    attribute(:url, :string, allow_nil?: false)

    attribute(:secret_ciphertext, :string, allow_nil?: false, sensitive?: true)
    attribute(:previous_secret_ciphertext, :string, allow_nil?: true, sensitive?: true)
    attribute(:secret_rotation_expires_at, :utc_datetime_usec, allow_nil?: true)

    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:active, :boolean, allow_nil?: false, default: true)
    attribute(:verified_at, :utc_datetime_usec, allow_nil?: false)

    attribute(:delivered_seq, :integer, allow_nil?: false, default: 0)
    # Why delivery last stopped, for whoever looks into it; never shown.
    attribute(:last_error, :string, allow_nil?: true)

    timestamps()
  end
end
