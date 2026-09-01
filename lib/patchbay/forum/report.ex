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

  relationships do
    belongs_to(:tool, Patchbay.Forum.Tool, allow_nil?: false, public?: true)
    has_many(:replies, Patchbay.Forum.Reply)
  end

  actions do
    defaults([:read])

    read :for_tool do
      description("Newest reports first.")
      argument(:tool_id, :uuid, allow_nil?: false)
      filter(expr(tool_id == ^arg(:tool_id)))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
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

      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})

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
