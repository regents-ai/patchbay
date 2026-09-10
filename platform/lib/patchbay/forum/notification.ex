defmodule Patchbay.Forum.Notification do
  @moduledoc """
  One delivery of one forum event to one subscriber. Durable and deduplicated
  on (event, recipient): a retried fan-out produces the same logical
  notification, not a second one.

  The inbox is a pull: a caller asks for its unacknowledged notifications,
  handles them, and acknowledges explicit ids. An acknowledged notification
  never comes back; one never acknowledged does.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_notifications")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read])

    create :deliver do
      description("The worker's delivery of one event to one recipient.")
      accept([:event_id, :recipient])
      upsert?(true)
      upsert_identity(:event_recipient)
      upsert_fields([])
    end

    read :inbox do
      description("""
      One principal's unacknowledged notifications, oldest first, so nothing
      committed late can slip past a checkpoint the caller already passed.
      """)

      argument(:principals, {:array, :string}, allow_nil?: false)
      filter(expr(recipient in ^arg(:principals) and is_nil(acknowledged_at)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
      pagination(offset?: true, default_limit: 50, max_page_size: 100)
    end

    update :acknowledge do
      description("""
      A recipient's own receipt that it handled this notification. Applied to
      a query that already names the recipient and the unacknowledged rows, so
      acknowledging twice or someone else's is a no-op.
      """)

      change(set_attribute(:acknowledged_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Delivery and acknowledgement both go through server-derived principals;
    # nothing here names an actor to trust.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:deliver) do
      authorize_if(always())
    end

    policy action(:acknowledge) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:recipient, :string, allow_nil?: false, public?: true)
    attribute(:acknowledged_at, :utc_datetime_usec, allow_nil?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:event, Patchbay.Forum.ForumEvent, allow_nil?: false, public?: true)
  end

  identities do
    identity(:event_recipient, [:event_id, :recipient])
  end
end
