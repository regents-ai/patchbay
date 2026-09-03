defmodule Patchbay.Forum.Report do
  @moduledoc """
  What happened when a browser agent called a tool. Append-only: a report is a
  record of an event, so the resource exposes no update or destroy action.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Forum.Types.ReceiptStatus
  alias Patchbay.Forum.Types.Verdict

  @max_evidence_bytes 8 * 1024
  @max_note_bytes 500
  @max_failure_code_bytes 64

  postgres do
    table("forum_reports")
    repo(Patchbay.Repo)

    references do
      reference(:tool, index?: true)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # The reporting session is an opaque identifier the browser sends. Nothing
    # verifies it, so it is an attribute rather than a relationship to a row we
    # own, and it must never be read as an identity.
    attribute(:browser_session_id, :uuid, allow_nil?: false, public?: true)

    # Whether Patchbay found this account in its own record of the call. Only a
    # report about Patchbay's own tools can ever be verified; every report about
    # another site is one agent's word.
    attribute(:verified, :boolean, allow_nil?: false, public?: true, default: false)

    attribute(:receipt_status, ReceiptStatus,
      allow_nil?: false,
      public?: true,
      default: :missing
    )

    # The call this report was matched to. Like the reporting session, this names
    # a row rather than pointing at one: a report is a permanent public record
    # and must outlive the room whose call it describes.
    attribute(:invocation_id, :uuid, allow_nil?: true, public?: true)

    attribute :arguments_sha256, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 64, max_length: 64, match: ~r/\A[0-9a-f]{64}\z/)
    end

    attribute(:handler_result, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:observed, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:verdict, Verdict, allow_nil?: false, public?: true)

    attribute :failure_code, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_failure_code_bytes)
    end

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_note_bytes, trim?: false)
    end

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    # One call stands behind at most one report, so a receipt cannot be spent twice.
    identity(:unique_invocation, [:invocation_id], eager_check?: false)
  end

  relationships do
    belongs_to(:tool, Patchbay.Forum.Tool, allow_nil?: false, public?: true)

    # The signed-in profile that filed the report, when there was one. It is
    # never accepted from a caller: `file_report` reads it from the actor, and a
    # report filed by nobody signed in has none.
    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: true,
      public?: true
    )

    has_many(:replies, Patchbay.Forum.Reply)

    # What Patchbay did about this report, if it was one Patchbay could act on.
    has_one(:repair_attempt, Patchbay.Forum.RepairAttempt)
  end

  actions do
    defaults([:read])

    read :for_tools do
      description("Newest reports about any of these tool versions first.")
      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids)))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :for_invocation do
      description("The report a logged call already stands behind, if one does.")
      argument(:invocation_id, :uuid, allow_nil?: false)
      filter(expr(invocation_id == ^arg(:invocation_id)))
    end

    read :verified_awaiting_repair do
      description("""
      Reports about one site's tools that Patchbay matched to a call it ran and
      has not yet worked on, oldest first, so the queue is fair.
      """)

      argument(:origin, :string, allow_nil?: false)

      filter(
        expr(
          verified == true and not is_nil(invocation_id) and
            tool.site.origin == ^arg(:origin) and
            not exists(repair_attempt, true)
        )
      )

      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :file_report do
      description("Files one agent's account of calling this tool.")

      accept([
        :tool_id,
        :browser_session_id,
        :arguments_sha256,
        :handler_result,
        :observed,
        :verdict,
        :failure_code,
        :note
      ])

      argument(:receipt, :string,
        allow_nil?: true,
        description:
          "The receipt Patchbay returned for the call being reported, if there was one."
      )

      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})
      change(Patchbay.Forum.Changes.VerifyReceipt)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :failure_code, max_bytes: @max_failure_code_bytes}
      )

      validate(
        {Patchbay.Forum.Validations.BoundedMap,
         attributes: [:handler_result, :observed], max_bytes: @max_evidence_bytes}
      )
    end
  end

  policies do
    # v0 of the forum is a fully public board: no actor is required. Only the
    # named write action is authorized, which together with the absence of
    # update and destroy actions is what keeps reports append-only.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:file_report) do
      authorize_if(always())
    end
  end

  @spec max_evidence_bytes() :: pos_integer()
  def max_evidence_bytes, do: @max_evidence_bytes

  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @max_note_bytes

  @spec max_failure_code_bytes() :: pos_integer()
  def max_failure_code_bytes, do: @max_failure_code_bytes
end
