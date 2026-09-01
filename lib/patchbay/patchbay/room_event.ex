defmodule Patchbay.Patchbay.RoomEvent do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Types.EventKind

  postgres do
    table("room_events")
    repo(Patchbay.Repo)

    references do
      reference(:browser_session, match_with: [room_id: :room_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:sequence, :integer, allow_nil?: false, public?: true)
    attribute(:kind, EventKind, allow_nil?: false, public?: true)
    attribute(:payload, :map, allow_nil?: false, public?: true, default: %{})

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_sequence_per_room, [:room_id, :sequence], eager_check?: true)
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true
    belongs_to :browser_session, Patchbay.Patchbay.BrowserSession, allow_nil?: true, public?: true
  end

  actions do
    defaults([:read])

    create :append do
      accept([:room_id, :browser_session_id, :sequence, :kind, :payload])

      validate(
        {Patchbay.Patchbay.Validations.RelationshipsSameRoom,
         relationships: [browser_session_id: Patchbay.Patchbay.BrowserSession]}
      )
    end
  end

  policies do
    # Timeline events are append-only public evidence for this room.
    policy always() do
      authorize_if(always())
    end
  end
end
