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
      reference(:room, on_delete: :delete)
      reference(:parent_revision, match_with: [room_id: :room_id], on_delete: :delete)
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

    read :for_update do
      prepare(build(lock: :for_update))
    end

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

    # A revision becomes the one the room offers straight from the seed
    # (:candidate), from a repair the owner approved (:approved), or from the
    # shelf when a demo reset puts the original tool back (:retired).
    update :set_desired do
      public?(false)
      accept([])
      require_atomic?(false)
      validate(one_of(:status, [:candidate, :approved, :retired]))
      change(set_attribute(:status, :desired))
      change(Patchbay.Patchbay.Changes.SyncDesiredRevision)
    end

    update :mark_canary_passed do
      public?(false)
      accept([])
      validate(attribute_equals(:status, :candidate))
      change(set_attribute(:status, :canary_passed))
    end

    update :mark_ready_for_approval do
      public?(false)
      accept([])
      validate(attribute_equals(:status, :canary_passed))
      change(set_attribute(:status, :ready_for_approval))
    end

    update :mark_approved do
      public?(false)
      accept([])
      validate(attribute_equals(:status, :ready_for_approval))
      change(set_attribute(:status, :approved))
    end

    update :retire do
      accept([])
      validate(attribute_does_not_equal(:status, :retired))
      change(set_attribute(:status, :retired))
      change(set_attribute(:retired_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Contract fields have no accepting update action, so reads are open and the
    # named lifecycle actions below can only move a revision through publication
    # statuses. Anything not named here stays forbidden.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([
             :create_revision,
             :set_desired,
             :mark_canary_passed,
             :mark_ready_for_approval,
             :mark_approved,
             :retire
           ]) do
      authorize_if(always())
    end
  end
end
