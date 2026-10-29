defmodule Patchbay.Forum.EventSubscription do
  @moduledoc """
  One MCP events subscription: a connection's request to have one kind of
  board event posted to its callback address as it happens.

  The id is derived from the owner, the event name, the filter and the
  callback address (`Regent.MCPEvents.subscription_id/4`), so subscribing
  again with the same four is a refresh of this row, never a second one, and
  nobody can name another owner's subscription.

  `:subscribe` (`Patchbay.Forum.subscribe_to_events/2`) holds every rule
  for starting one: its callback answers a signed challenge before anything
  is stored; an account holds at most `per_account/0` live ones, whichever of
  its connections made them, counted before the challenge and again under
  the account's lock; refreshing a live one is never refused. `:unsubscribe`
  (`Patchbay.Forum.unsubscribe_from_events/2`) ends the actor's own.

  Delivery reads the committed event stream (`ForumEvent`) forward from
  `delivered_seq`, the last event the callback acknowledged. The `:deliver`
  trigger runs one Oban job per subscription at a time, queued when a board
  event lands, when the subscription starts or is refreshed, and by a sweep
  every minute. A failed event is retried by Oban with backoff and never
  stepped over: `delivered_seq` moves only when the callback acknowledges.
  When the attempts run out, the subscription stops where it was, and a
  refresh resumes it from the same event.

  A subscription that has run out is removed by the `:forget_lapsed`
  trigger, looked for every hour; subscribing again starts a new one.

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
                events,
                seq > parent(delivered_seq) and
                  ((parent(name) == "reply_created" and kind == :reply_posted) or
                     (parent(name) == "solution_marked" and kind == :solution_marked))
              )
          )
        )

        worker_module_name(Patchbay.Forum.EventSubscription.Workers.Deliver)
        scheduler_module_name(Patchbay.Forum.EventSubscription.Schedulers.Deliver)
      end

      # A subscription that has run out is removed, so it no longer holds a
      # row; looked for every hour.
      trigger :forget_lapsed do
        action(:forget)
        queue(:lapsed_subscriptions)
        where(expr(expires_at <= now()))
        scheduler_cron("0 * * * *")
        max_attempts(3)
        lock_for_update?(false)
        worker_module_name(Patchbay.Forum.EventSubscription.Workers.ForgetLapsed)
        scheduler_module_name(Patchbay.Forum.EventSubscription.Schedulers.ForgetLapsed)
      end
    end
  end

  @doc "The most live subscriptions one account holds."
  @spec per_account() :: pos_integer()
  def per_account, do: 20

  relationships do
    # The whole board event stream; the trigger's filter picks what is owed.
    has_many :events, Patchbay.Forum.ForumEvent do
      no_attributes?(true)
    end
  end

  postgres do
    table("forum_event_subscriptions")
    repo(Patchbay.Repo)

    custom_indexes do
      # The account's live subscriptions, counted before each new one.
      index([:owner_id, :expires_at])
    end
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change(Patchbay.OAuth.AttributeEventAuthority)
    end

    create :subscribe do
      description("""
      Starts a subscription, or refreshes the one with the same event, filter
      and callback, once its callback has answered a challenge.
      """)

      # The id is derived from the actor, the event, the filter and the
      # callback, so a second subscribe with the same four refreshes this
      # row, keeping its place in the stream.
      upsert?(true)

      upsert_fields([
        :expires_at,
        :verified_at,
        :active,
        :last_error,
        :secret_ciphertext,
        :previous_secret_ciphertext,
        :secret_rotation_expires_at,
        :acting_agent_id,
        :beneficiary_profile_id,
        :human_account_id,
        :pairing_id,
        :oauth_token_id,
        :oauth_client_id
      ])

      accept([:name, :arguments, :url])
      argument(:secret, :string, allow_nil?: false, sensitive?: true)
      # At most a day; a day when left out.
      argument(:ttl_ms, :integer, constraints: [min: 1])
      argument(:cursor, :string)
      metadata(:truncated, :boolean, allow_nil?: false)

      change(Patchbay.Forum.Changes.DeriveEventSubscription)
      # Looked at before the callback is sent anything ...
      validate(Patchbay.Forum.Validations.EventSubscriptionRoom)
      change(Patchbay.Forum.Changes.ChallengeCallback)
      # ... and again under the account's lock, just before the save.
      change(Patchbay.Forum.Changes.LockEventOwner)
      validate(Patchbay.Forum.Validations.EventSubscriptionRoom, before_action?: true)
      change(Patchbay.Forum.Changes.ResumeEventStream)
      change(Patchbay.OAuth.AttributeEventAuthority)
      change(run_oban_trigger(:deliver))
    end

    action :unsubscribe do
      description("Ends the actor's own subscription to one event, filter and callback.")
      transaction?(true)
      argument(:name, :string, allow_nil?: false)
      argument(:arguments, :map, allow_nil?: false)
      argument(:url, :string, allow_nil?: false)
      run(Patchbay.Forum.Actions.UnsubscribeFromEvents)
    end

    update :deliver do
      description("""
      Posts the events the subscriber is owed, in order, each outside any
      transaction. Run by the `:deliver` trigger; see `Patchbay.Forum.EventDelivery`.
      """)

      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Forum.EventDelivery)
    end

    destroy :forget do
      description("Removes a subscription that has run out. Run by the `:forget_lapsed` trigger.")
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
    policy action([:subscribe, :destroy]) do
      authorize_if(Patchbay.OAuth.EventAccess)
    end

    # Ending one is authorized again on the subscription itself (`:destroy`).
    policy action(:unsubscribe) do
      authorize_if(actor_present())
    end
  end

  attributes do
    attribute :id, :string do
      primary_key?(true)
      allow_nil?(false)
      writable?(true)
    end

    attribute(:acting_agent_id, :uuid)
    attribute(:beneficiary_profile_id, :uuid)
    attribute(:human_account_id, :integer)
    attribute(:pairing_id, :uuid)
    attribute(:oauth_token_id, :uuid, sensitive?: true)
    attribute(:oauth_client_id, :uuid)
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
