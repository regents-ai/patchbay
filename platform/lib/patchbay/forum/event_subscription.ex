defmodule Patchbay.Forum.EventSubscription do
  @moduledoc """
  One MCP events subscription: a connection's request to have one kind of
  board event posted to its callback address as it happens.

  The id is derived from the owner, the event name, the filter and the
  callback address (`Regent.MCPEvents.subscription_id/4`), so subscribing
  again with the same four is a refresh of this row, never a second one, and
  nobody can name another owner's subscription.

  Delivery reads the committed event stream (`ForumEvent`) forward from
  `delivered_seq`, the last event the callback acknowledged. There is one
  outstanding event per subscription at a time: `pending_seq` is the event
  being attempted, `attempt` how many times, and a retry or a stop leaves
  `delivered_seq` where it was, so nothing behind a failure is ever sent
  ahead of it. A lease (`lease_token` until `lease_expires_at`) fences each
  attempt, and an attempt is finished only by the holder of its lease.

  The signing secrets are stored encrypted (`Patchbay.Forum.EventSecret`)
  and never leave the server except as webhook signatures.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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
    end

    update :refresh do
      description("""
      Extends a subscription and resumes it, keeping its place in the stream.
      The outstanding event gets a fresh set of attempts, and any attempt
      under way loses its lease, so it can neither finish nor halt the row.
      """)

      require_atomic?(false)
      accept([:expires_at, :verified_at])
      argument(:secret_ciphertext, :string, allow_nil?: false, sensitive?: true)
      argument(:rotation_ends_at, :utc_datetime_usec, allow_nil?: false)

      change(set_attribute(:active, true))
      change(set_attribute(:attempt, 0))
      change(set_attribute(:lease_token, nil))
      change(set_attribute(:lease_expires_at, nil))
      change(set_attribute(:next_attempt_at, nil))
      change(set_attribute(:last_error, nil))
      change(Patchbay.Forum.Changes.RotateEventSecret)
    end

    update :skip_to do
      description("Moves past events that are not the subscriber's to receive.")
      accept([:delivered_seq])
    end

    update :lease do
      description("Claims the subscription's earliest outstanding event for one attempt.")
      accept([:lease_token, :lease_expires_at, :pending_seq, :attempt])
    end

    update :delivered do
      description("The callback acknowledged the outstanding event.")
      change(atomic_update(:delivered_seq, expr(pending_seq)))
      change(set_attribute(:pending_seq, nil))
      change(set_attribute(:attempt, 0))
      change(set_attribute(:lease_token, nil))
      change(set_attribute(:lease_expires_at, nil))
      change(set_attribute(:last_error, nil))
    end

    update :retry_later do
      description("The attempt failed for now; the same event is tried again at next_attempt_at.")
      accept([:next_attempt_at, :last_error])
      change(set_attribute(:lease_token, nil))
      change(set_attribute(:lease_expires_at, nil))
    end

    update :halt do
      description("Delivery stopped; the outstanding event stays outstanding until a refresh.")
      accept([:last_error])
      change(set_attribute(:active, false))
      change(set_attribute(:lease_token, nil))
      change(set_attribute(:lease_expires_at, nil))
    end
  end

  policies do
    # There is no public way in. The MCP door subscribes for the connection's
    # own server-derived principal, and the delivery worker reads and writes
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
    attribute(:pending_seq, :integer, allow_nil?: true)
    attribute(:attempt, :integer, allow_nil?: false, default: 0)
    attribute(:lease_token, :string, allow_nil?: true)
    attribute(:lease_expires_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:next_attempt_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:last_error, :string, allow_nil?: true)

    timestamps()
  end
end
