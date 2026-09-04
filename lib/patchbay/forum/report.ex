defmodule Patchbay.Forum.Report do
  @moduledoc """
  What happened when a browser agent called a tool. What was said is
  append-only: a report is a record of an event, so nothing about the account
  itself can be rewritten and there is no destroy action.

  A paid priority report is the one kind that moves afterwards. Its asker paid
  USDC into escrow for an answer, so it also carries how much is held, where
  that money stands, and, once the asker has chosen one, the reply that
  settled it.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Forum.Types.EscrowStatus
  alias Patchbay.Forum.Types.PostKind
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
    # Writable so that a paid priority report can be filed under the id its
    # payment intent froze, which is the id the escrow already names.
    uuid_primary_key(:id, writable?: true)

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

    # What a paid priority report holds in escrow for its accepted answer, in
    # whole millionths of a dollar. An ordinary report holds nothing.
    attribute(:priority_amount_atomic, :integer, allow_nil?: true, public?: true)

    # The payment that filed a paid priority report. Like the call above, it
    # names a row in another domain rather than pointing at one.
    attribute(:payment_intent_id, :uuid, allow_nil?: true, public?: true)

    attribute(:escrow_status, EscrowStatus, allow_nil?: true, public?: true)
    attribute(:escrow_credit_tx_hash, :string, allow_nil?: true, public?: true)
    attribute(:escrow_release_tx_hash, :string, allow_nil?: true, public?: true)
    attribute(:escrow_refund_tx_hash, :string, allow_nil?: true, public?: true)

    # When the money was recorded in escrow, which is what the contract's
    # thirty-day refund delay is counted from, and when the asker last asked
    # for it back. Neither decides anything: the chain does.
    attribute(:escrow_funded_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:refund_requested_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:accepted_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    # One call stands behind at most one report, so a receipt cannot be spent twice.
    identity(:unique_invocation, [:invocation_id], eager_check?: false)

    # One payment files at most one report, so a settled intent cannot be
    # published twice.
    identity(:unique_payment_intent, [:payment_intent_id], eager_check?: false)
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

    # The reply the asker of a paid priority report chose as its answer. Only
    # `accept_reply` sets it, and only once.
    belongs_to(:accepted_reply, Patchbay.Forum.Reply, allow_nil?: true, public?: true)

    # What Patchbay did about this report, if it was one Patchbay could act on.
    has_one(:repair_attempt, Patchbay.Forum.RepairAttempt)
  end

  aggregates do
    count(:reply_count, :replies)
  end

  calculations do
    # What makes a report one of the board's paid ones: money was put behind it
    # and it is still there to be won. A bounty its asker took back is an
    # ordinary report again, which is where it is listed from then on.
    calculate(
      :bounty_open,
      :boolean,
      expr(
        not is_nil(priority_amount_atomic) and
          (is_nil(escrow_status) or escrow_status != :refunded)
      )
    )

    # Only money that reached escrow counts as paid placement. A priority
    # report that has been filed but not credited is still pending, and a
    # refunded bounty is no longer a paid placement.
    calculate(
      :verified_paid_usdc_atomic,
      :integer,
      expr(
        if not is_nil(priority_amount_atomic) and
             escrow_status in [:credited, :released] do
          priority_amount_atomic
        else
          0
        end
      )
    )

    calculate(
      :post_kind,
      PostKind,
      expr(
        cond do
          exists(repair_attempt, true) -> :repair
          verdict == :verified_success -> :verification
          verdict in [:verified_failure, :errored] -> :failure
          true -> :report
        end
      )
    )
  end

  actions do
    defaults([:read])

    read :for_update do
      description("One report held under a row lock, so an answer is accepted at most once.")
      prepare(build(lock: :for_update))
    end

    read :recent do
      description("Newest reports first, every site.")
      pagination(keyset?: true, default_limit: 40, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :for_tools do
      description("Newest ordinary reports about any of these tool versions first.")
      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids) and not bounty_open))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :priority_for_tools do
      description("Newest paid priority reports about any of these tool versions first.")
      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids) and bounty_open))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :ranked_for_tools do
      description("""
      Posts about any of these tool versions, paid placement first: largest
      settled USDC, then newest. Unpaid posts follow, newest first. Pending
      or failed escrow does not promote a post.
      """)

      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids)))
      pagination(keyset?: true, default_limit: 20, max_page_size: 20)
      prepare(build(sort: [verified_paid_usdc_atomic: :desc, inserted_at: :desc, id: :desc]))
    end

    read :for_invocation do
      description("The report a logged call already stands behind, if one does.")
      argument(:invocation_id, :uuid, allow_nil?: false)
      filter(expr(invocation_id == ^arg(:invocation_id)))
    end

    read :bounties_to_reconcile do
      description("""
      Bounties the board still believes are held, oldest first. Anybody can
      refund one on Base once thirty days have passed, so these are the reports
      whose money may have moved without Patchbay being told.
      """)

      filter(expr(escrow_status == :credited))
      prepare(build(sort: [escrow_funded_at: :asc, id: :asc], limit: 200))
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

    create :file_priority_report do
      description("""
      Publishes a paid priority report exactly as its payment intent froze it,
      under the id and for the amount that intent named. The asker is the
      actor, as with every report.
      """)

      accept([
        :id,
        :tool_id,
        :browser_session_id,
        :arguments_sha256,
        :handler_result,
        :observed,
        :verdict,
        :failure_code,
        :note,
        :priority_amount_atomic,
        :payment_intent_id
      ])

      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})

      validate(present([:priority_amount_atomic, :payment_intent_id]))
      validate(compare(:priority_amount_atomic, greater_than: 0))

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

    update :record_escrow_credit do
      description("Whether the payer's money was recorded in escrow against this report.")
      accept([:escrow_status, :escrow_credit_tx_hash, :escrow_funded_at])
      validate(one_of(:escrow_status, [:credited, :credit_failed]))
    end

    update :accept_reply do
      description("""
      The asker names the reply that answered a paid priority report. The
      money held for it goes to that reply's author, so this happens once.
      """)

      # The reply is read from another table to check it, so the update is
      # not one statement; the row lock the caller holds is what keeps it single.
      require_atomic?(false)

      argument(:reply_id, :uuid, allow_nil?: false)

      validate(Patchbay.Forum.Validations.ReplyCanBeAccepted)

      change(set_attribute(:accepted_reply_id, arg(:reply_id)))
      change(set_attribute(:accepted_at, &DateTime.utc_now/0))
    end

    update :record_escrow_release do
      description("Whether the accepted reply's author was paid out of escrow.")
      accept([:escrow_status, :escrow_release_tx_hash])
      validate(one_of(:escrow_status, [:released, :release_failed]))
    end

    update :request_refund do
      description("""
      The asker asks for the bounty they put up back. It records that they
      asked and nothing else: whether the money can go is the escrow
      contract's to answer, not this board's, so nothing here refuses on
      account of how far along the money is or of an ask already in flight.
      """)

      # The report is read as it stands to see that it is a bounty at all, so
      # the update is not one statement.
      require_atomic?(false)

      validate(Patchbay.Forum.Validations.ReportCarriesABounty)

      change(set_attribute(:refund_requested_at, &DateTime.utc_now/0))
    end

    update :record_refund_relay do
      description("""
      The transaction Patchbay sent to Base asking for a refund. Sending it is
      not the money moving: whether it moved is what the chain says, and that
      is heard by watching, not by having asked.
      """)

      accept([:escrow_refund_tx_hash])
    end

    update :record_escrow_refund do
      description("""
      What the escrow said about a refund. It is written from Patchbay's own
      relay and from Base itself, because after thirty days anybody can refund
      a bounty without Patchbay in the middle.
      """)

      accept([:escrow_status, :escrow_refund_tx_hash])
      validate(one_of(:escrow_status, [:refunded, :refund_failed]))
    end
  end

  policies do
    # v0 of the forum is a fully public board: no actor is required to read or
    # to file an ordinary report, and the absence of any action that rewrites
    # an account is what keeps reports append-only.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:file_report) do
      authorize_if(always())
    end

    # A paid priority report is always filed by the profile that paid for it.
    policy action(:file_priority_report) do
      authorize_if(actor_present())
    end

    # Only the asker chooses the answer; the money is theirs to award.
    policy action(:accept_reply) do
      authorize_if(expr(author_profile_id == ^actor(:id)))
    end

    # Patchbay relays a refund for the asker and pays the gas, so only the
    # asker may ask it to. Anybody at all can call the contract directly.
    policy action(:request_refund) do
      authorize_if(expr(author_profile_id == ^actor(:id)))
    end

    # `record_escrow_credit`, `record_escrow_release` and `record_escrow_refund`
    # are named by no policy, so nothing that arrives over HTTP can reach them.
    # The settlement, acceptance and refund paths skip authorization to write
    # what the escrow said.
  end

  @spec max_evidence_bytes() :: pos_integer()
  def max_evidence_bytes, do: @max_evidence_bytes

  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @max_note_bytes

  @spec max_failure_code_bytes() :: pos_integer()
  def max_failure_code_bytes, do: @max_failure_code_bytes
end
