defmodule Patchbay.Patchbay.Invocation do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Receipt
  alias Patchbay.Patchbay.Types.{FailureCode, InvocationStatus}

  postgres do
    table("invocations")
    repo(Patchbay.Repo)

    # Receipts are minted in Elixir, so the database default only covers rows the
    # table already held when the column arrived. Those receipts were never
    # handed to anyone, which is exactly right: no report can quote them.
    migration_defaults(
      receipt:
        "fragment(\"rtrim(translate(encode(uuid_send(gen_random_uuid()), 'base64'), '+/', '-_'), '=')\")"
    )

    references do
      reference(:room, on_delete: :delete)
      reference(:browser_session, match_with: [room_id: :room_id], on_delete: :delete)
      reference(:tool_revision, match_with: [room_id: :room_id], on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:request_uuid, :uuid, allow_nil?: false, public?: true)

    # Handed to the agent with the result and printed on the call's log line, so
    # a later report can be tied back to this exact call. Never accepted from a
    # caller: the server is the only thing that may mint one.
    attribute :receipt, :string do
      allow_nil?(false)
      public?(true)
      default(&Receipt.generate/0)
      constraints(min_length: 22, max_length: 22, match: ~r/\A[A-Za-z0-9_-]{22}\z/, trim?: false)
    end

    attribute(:invocation_epoch, :integer, allow_nil?: false, public?: true, default: 0)
    attribute(:tool_contract_sha256, :string, allow_nil?: false, public?: true)
    attribute(:arguments, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:arguments_sha256, :string, allow_nil?: false, public?: true)
    attribute(:pre_state, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:handler_result, :map, allow_nil?: false, public?: true, default: %{})

    attribute(:handler_reported_success, :boolean,
      allow_nil?: false,
      public?: true,
      default: false
    )

    attribute :generated_candidate, :string do
      allow_nil?(true)
      public?(true)
      sensitive?(true)
      constraints(max_length: 65_536, trim?: false)
    end

    attribute(:generated_candidate_sha256, :string, allow_nil?: true, public?: true)
    attribute(:generation_key, :string, allow_nil?: true, public?: true)
    attribute(:post_state, :map, allow_nil?: false, public?: true, default: %{})

    attribute(:effective_status, InvocationStatus,
      allow_nil?: false,
      public?: true,
      default: :started
    )

    attribute(:failure_code, FailureCode, allow_nil?: true, public?: true)
    attribute(:duration_ms, :integer, allow_nil?: true, public?: true)

    attribute(:started_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:handler_returned_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:verified_at, :utc_datetime_usec, allow_nil?: true, public?: true)
  end

  identities do
    # The service uses the database unique index as the serialization point for
    # duplicate deliveries. An eager read would reintroduce a check-then-insert
    # race under concurrent requests.
    identity(:unique_request_uuid, [:request_uuid], eager_check?: false)
    identity(:unique_id_per_room, [:id, :room_id], eager_check?: false)
    identity(:unique_receipt, [:receipt], eager_check?: false)
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true

    belongs_to :browser_session, Patchbay.Patchbay.BrowserSession,
      allow_nil?: false,
      public?: true

    belongs_to :tool_revision, Patchbay.Patchbay.ToolRevision, allow_nil?: false, public?: true
  end

  actions do
    defaults([:read])

    read :for_update do
      prepare(build(lock: :for_update))
    end

    create :record_invocation do
      touches_resources([Patchbay.Patchbay.Room])

      accept([
        :request_uuid,
        :invocation_epoch,
        :room_id,
        :browser_session_id,
        :tool_revision_id,
        :tool_contract_sha256,
        :arguments,
        :handler_result,
        :handler_reported_success,
        :generated_candidate,
        :duration_ms,
        :started_at
      ])

      # The room lock is what decides the recorded pre-state. A caller may say
      # which state it believes it acted on, and is turned away if it disagrees.
      argument(:pre_state, :map)

      change(Patchbay.Patchbay.Changes.CaptureInvocationPreState)
      change(Patchbay.Patchbay.Changes.RecomputeGeneratedCandidate)
    end

    update :mark_executing do
      accept([])
      change(set_attribute(:effective_status, :executing))
    end

    update :record_handler_return do
      accept([
        :handler_result,
        :handler_reported_success,
        :generated_candidate,
        :handler_returned_at
      ])

      change(set_attribute(:effective_status, :handler_returned))
      change(Patchbay.Patchbay.Changes.RecomputeGeneratedCandidate)
      require_atomic?(false)
    end

    update :mark_awaiting_visible_state do
      public?(false)
      accept([])
      change(set_attribute(:effective_status, :awaiting_visible_state))
    end

    update :mark_errored do
      public?(false)
      accept([])
      change(set_attribute(:effective_status, :errored))
    end

    update :mark_cancelled do
      public?(false)
      accept([])
      change(set_attribute(:effective_status, :cancelled))
    end

    update :record_verification do
      public?(false)
      accept([:post_state, :failure_code, :verified_at])

      change(Patchbay.Patchbay.Changes.RecordVerification)

      require_atomic?(false)
    end
  end

  policies do
    # Invocation rows are public evidence for the seeded demo, so reads are
    # open. The named writes below are the whole life of a call; a row can only
    # be written by moving it along that line.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([
             :record_invocation,
             :mark_executing,
             :record_handler_return,
             :mark_awaiting_visible_state,
             :mark_errored,
             :mark_cancelled,
             :record_verification
           ]) do
      authorize_if(always())
    end
  end
end
