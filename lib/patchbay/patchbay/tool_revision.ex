defmodule Patchbay.Patchbay.ToolRevision do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Patchbay.Types.{HandlerAdapter, PostconditionSet, RevisionOrigin, RevisionStatus}

  postgres do
    table("tool_revisions")
    repo(Patchbay.Repo)

    identity_wheres_to_sql(
      unique_active_generation_per_room: "status <> 'retired'",
      unique_desired_revision_per_room: "status = 'desired'"
    )

    references do
      reference(:parent_revision, match_with: [room_id: :room_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:parent_revision_id, :uuid, allow_nil?: true, public?: true)
    attribute(:generation, :integer, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, allow_nil?: false, public?: true)
    attribute(:input_schema, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:annotations, :map, allow_nil?: false, public?: true, default: %{})

    attribute(:handler_adapter, HandlerAdapter, allow_nil?: false, public?: true)
    attribute(:output_contract, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:postcondition_set, PostconditionSet, allow_nil?: false, public?: true)

    attribute :contract_sha256, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 64, max_length: 64)
    end

    attribute(:origin, RevisionOrigin, allow_nil?: false, public?: true, default: :seed)
    attribute(:status, RevisionStatus, allow_nil?: false, public?: true, default: :candidate)
    attribute(:published_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:retired_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_active_generation_per_room, [:room_id, :generation],
      where: expr(status != :retired),
      eager_check?: false
    )

    identity(:unique_id_per_room, [:id, :room_id], eager_check?: false)
    # Ash's eager identity query cannot apply a partial identity's `where`
    # clause. Let the generated PostgreSQL partial index enforce this invariant
    # so retiring a desired revision permits a later demo run to reuse it.
    identity(:unique_desired_revision_per_room, [:room_id],
      where: expr(status == :desired),
      eager_check?: false
    )
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true
    belongs_to :parent_revision, __MODULE__, allow_nil?: true, public?: true
  end

  actions do
    defaults([:read])

    create :create_revision do
      touches_resources([Patchbay.Patchbay.Room])

      accept([
        :room_id,
        :parent_revision_id,
        :generation,
        :name,
        :title,
        :description,
        :input_schema,
        :annotations,
        :handler_adapter,
        :output_contract,
        :postcondition_set,
        :origin,
        :status,
        :published_at,
        :retired_at
      ])

      change(Patchbay.Patchbay.Changes.SetContractDigest)
      change(Patchbay.Patchbay.Changes.SyncDesiredRevision)
    end

    update :set_desired do
      public?(false)
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :desired))
      change(Patchbay.Patchbay.Changes.SyncDesiredRevision)
    end

    update :mark_canary_passed do
      public?(false)
      accept([])
      change(set_attribute(:status, :canary_passed))
    end

    update :mark_ready_for_approval do
      public?(false)
      accept([])
      change(set_attribute(:status, :ready_for_approval))
    end

    update :mark_approved do
      public?(false)
      accept([])
      change(set_attribute(:status, :approved))
    end

    update :mark_observed_active do
      accept([])
      change(set_attribute(:status, :observed_active))
    end

    update :retire do
      accept([])
      change(set_attribute(:status, :retired))
      change(set_attribute(:retired_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Contract fields have no accepting update action. The named lifecycle
    # actions above can only move a revision through publication statuses.
    policy always() do
      authorize_if(always())
    end
  end
end
