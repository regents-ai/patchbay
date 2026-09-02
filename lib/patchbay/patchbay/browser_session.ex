defmodule Patchbay.Patchbay.BrowserSession do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("browser_sessions")
    repo(Patchbay.Repo)

    references do
      reference(:room, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :client_instance_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    # The forum identity the page issued this browser, so a receipt from this
    # session can only be reported by the same browser that was given it.
    attribute(:forum_session_id, :uuid, allow_nil?: true, public?: true)

    attribute(:user_agent_digest, :string, allow_nil?: false, public?: true)
    attribute(:webmcp_supported, :boolean, allow_nil?: false, public?: true, default: false)
    attribute(:desired_generation, :integer, allow_nil?: false, public?: true, default: 1)
    attribute(:observed_generation, :integer, allow_nil?: true, public?: true)

    attribute :observed_tool_names, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :observed_contracts, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute(:toolchange_count, :integer, allow_nil?: false, public?: true, default: 0)

    attribute(:connected_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:last_seen_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:disconnected_at, :utc_datetime_usec, allow_nil?: true, public?: true)
  end

  identities do
    identity(:unique_client_instance_id_per_room, [:room_id, :client_instance_id],
      eager_check?: true
    )

    identity(:unique_id_per_room, [:id, :room_id], eager_check?: false)
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true
  end

  actions do
    defaults([:read])

    read :for_update do
      prepare(build(lock: :for_update))
    end

    create :register do
      upsert?(true)
      upsert_identity(:unique_client_instance_id_per_room)
      upsert_fields([:user_agent_digest, :webmcp_supported, :forum_session_id])

      accept([
        :room_id,
        :client_instance_id,
        :forum_session_id,
        :user_agent_digest,
        :webmcp_supported
      ])
    end

    update :observe do
      touches_resources([Patchbay.Patchbay.Room])
      require_atomic?(false)

      accept([
        :webmcp_supported,
        :desired_generation,
        :observed_generation,
        :observed_tool_names,
        :observed_contracts,
        :toolchange_count,
        :last_seen_at
      ])

      change(Patchbay.Patchbay.Changes.ReestablishBrowserSession)
    end

    update :disconnect do
      accept([:disconnected_at])
    end

    update :reset_demo do
      accept([])
      require_atomic?(false)
      change(set_attribute(:webmcp_supported, false))
      change(set_attribute(:desired_generation, 1))
      change(set_attribute(:observed_generation, nil))
      change(set_attribute(:observed_tool_names, []))
      change(set_attribute(:observed_contracts, %{}))
      change(set_attribute(:toolchange_count, 0))
      change(set_attribute(:disconnected_at, &DateTime.utc_now/0))
      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Browser sessions are ephemeral observations in the public demo: reads are
    # open, and so are the four writes the room page and the demo reset make.
    # Anything not named here stays forbidden.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:register, :observe, :disconnect, :reset_demo]) do
      authorize_if(always())
    end
  end
end
