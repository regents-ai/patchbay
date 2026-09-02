defmodule Patchbay.Patchbay.RoomEvent do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Types.EventKind

  # How much of a room's history the page carries. A room that stays open all
  # day keeps appending, and the page only ever needs the recent end of it.
  @page_size 200

  postgres do
    table("room_events")
    repo(Patchbay.Repo)

    references do
      reference(:room, on_delete: :delete)
      reference(:browser_session, match_with: [room_id: :room_id], on_delete: :delete)
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

    # The newest page of one room's events, newest first, so the read itself
    # decides how much history leaves the database.
    read :recent_for_room do
      argument(:room_id, :uuid, allow_nil?: false)

      filter(expr(room_id == ^arg(:room_id)))

      prepare(build(sort: [sequence: :desc], limit: @page_size))
    end

    create :append do
      accept([:room_id, :browser_session_id, :sequence, :kind, :payload])
    end
  end

  policies do
    # Timeline events are append-only public evidence for this room: reads are
    # open, appending is the one named write, and there is nothing else.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:append) do
      authorize_if(always())
    end
  end

  @doc "How many of a room's most recent events a page of the timeline holds."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size
end
