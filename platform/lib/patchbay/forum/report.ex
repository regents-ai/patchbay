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

  alias Patchbay.Forum.Types.DiscussionState
  alias Patchbay.Forum.Types.EscrowStatus
  alias Patchbay.Forum.Types.PostKind
  alias Patchbay.Forum.Types.ReceiptStatus
  alias Patchbay.Forum.Types.ThreadKind
  alias Patchbay.Forum.Types.Verdict
  alias Patchbay.Forum.Types.Visibility

  @max_evidence_bytes 8 * 1024
  @max_note_bytes 500
  @max_failure_code_bytes 64
  @max_title_bytes 640
  @max_body_bytes 16 * 1024
  @max_subject_tool_name_bytes 64
  @max_client_request_id_bytes 128

  postgres do
    table("forum_reports")
    repo(Patchbay.Repo)

    references do
      reference(:tool, index?: true)
      reference(:site, index?: true)
    end
  end

  attributes do
    # Writable so that a paid priority report can be filed under the id its
    # payment intent froze, which is the id the escrow already names.
    uuid_primary_key(:id, writable?: true)

    # The reporting session is an opaque identifier the browser sends. Nothing
    # verifies it, so it is an attribute rather than a relationship to a row we
    # own, and it must never be read as an identity.
    attribute(:browser_session_id, :uuid, allow_nil?: true, public?: true)

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

    # The evidence fields below are nil on an ordinary question: asking one
    # invents no call, digest or verdict. Only the legacy report actions
    # require them.
    attribute :arguments_sha256, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 64, max_length: 64, match: ~r/\A[0-9a-f]{64}\z/)
    end

    attribute(:handler_result, :map, allow_nil?: true, public?: true)
    attribute(:observed, :map, allow_nil?: true, public?: true)
    attribute(:verdict, Verdict, allow_nil?: true, public?: true)

    # --- Ordinary conversation fields -------------------------------------

    # What kind of conversation this is. Rows filed before kinds existed, and
    # anything filed through the report actions, read as failure reports.
    attribute(:thread_kind, ThreadKind,
      allow_nil?: false,
      public?: true,
      default: :failure_report
    )

    attribute :title, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 160, trim?: false)
    end

    # The whole question, in Markdown. Historical reports carry their words in
    # `note` instead, which is kept verbatim.
    attribute(:body_markdown, :string, allow_nil?: true, public?: true)

    # The name of the tool the thread is about when no observed version is
    # named. Context only: it is not proof a tool was observed.
    attribute :subject_tool_name, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 64, match: Patchbay.Forum.ToolName.shape())
    end

    attribute(:topic_tags, {:array, :string}, allow_nil?: false, public?: true, default: [])

    attribute(:discussion_state, DiscussionState,
      allow_nil?: false,
      public?: true,
      default: :open
    )

    # Moderation's word on whether this record may be shown. No public action
    # accepts it.
    attribute(:visibility, Visibility, allow_nil?: false, public?: true, default: :published)

    # A related or canonical conversation. A link, never a merge: escrow and
    # replies stay with their own record.
    attribute(:content_version, :integer, allow_nil?: false, public?: true, default: 1)

    # Rows seeded for demonstrations are excluded from product metrics.
    attribute(:demo_fixture, :boolean, allow_nil?: false, public?: true, default: false)

    # Bumped whenever a public reply or relevant status change lands, so feeds
    # can order by what moved last rather than what was posted first.
    attribute(:last_activity_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

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

    # The key a caller chose for its ask, and a digest of what it asked, so
    # the same ask sent twice is answered with this thread and the same key
    # sent with different words is refused. Only an ordinary question carries
    # them; nothing about a thread is decided by them.
    attribute :client_request_id, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 1, max_length: @max_client_request_id_bytes, trim?: false)
    end

    attribute :request_digest, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 64, max_length: 64, match: ~r/\A[0-9a-f]{64}\z/)
    end

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    # One call stands behind at most one report, so a receipt cannot be spent twice.
    identity(:unique_invocation, [:invocation_id], eager_check?: false)

    # One payment files at most one report, so a settled intent cannot be
    # published twice.
    identity(:unique_payment_intent, [:payment_intent_id], eager_check?: false)

    # One request key opens at most one thread for the session that chose it.
    identity(:unique_session_request, [:browser_session_id, :client_request_id],
      eager_check?: false
    )
  end

  relationships do
    # The site whose board the conversation is on. Always required; for a
    # report about a tool it is the tool's own site.
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)

    # The exact observed contract version the report is about, when there is
    # one. An ordinary question names a site only.
    belongs_to(:tool, Patchbay.Forum.Tool, allow_nil?: true, public?: true)

    # A related or canonical conversation this one points at.
    belongs_to(:duplicate_of, __MODULE__, allow_nil?: true, public?: true)

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

    # The reply the asker of an ordinary thread picked as what worked. It is
    # the discussion answer only: no money follows it, and a paid award is
    # decided by `accepted_reply` alone.
    belongs_to(:solution_reply, Patchbay.Forum.Reply, allow_nil?: true, public?: true)

    # The reusable cards distilled from this thread's named solutions.
    has_many :solution_cards, Patchbay.Forum.SolutionCard do
      destination_attribute(:thread_id)
      filter(expr(status == :published))
    end

    # What Patchbay did about this report, if it was one Patchbay could act on.
    has_one(:repair_attempt, Patchbay.Forum.RepairAttempt)

    # What Jev made of a paid priority report. It sorts and highlights only.
    has_one(:jev_reading, Patchbay.Forum.JevReading, public?: true)
  end

  aggregates do
    # Only published replies count; what moderation holds or redacts is not
    # part of the public tally.
    count(:reply_count, :replies) do
      filter(expr(visibility == :published))
    end
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

    # Only money that reached escrow counts as settled. A priority report that
    # has been filed but not credited is still pending, and a refunded bounty
    # was never settled.
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

    # What a list ranks by: a bounty that is funded and still waiting for its
    # answer. Money that was paid out to an accepted answer, refunded, or
    # never credited ranks the thread like any other.
    calculate(
      :open_bounty_usdc_atomic,
      :integer,
      expr(
        if not is_nil(priority_amount_atomic) and escrow_status == :credited and
             is_nil(accepted_reply_id) do
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
      description("Threads with the newest activity first, every site.")
      filter(expr(visibility == :published))
      pagination(keyset?: true, default_limit: 40, max_page_size: 200)
      prepare(build(sort: [last_activity_at: :desc, id: :desc]))
    end

    read :for_tools do
      description("Newest ordinary reports about any of these tool versions first.")
      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids) and not bounty_open and visibility == :published))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :priority_for_tools do
      description("Newest paid priority reports about any of these tool versions first.")
      argument(:tool_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(tool_id in ^arg(:tool_ids) and bounty_open and visibility == :published))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :ranked_for_tool do
      description("""
      Every published thread about one named tool on a site — posts filed
      against any version of it, and questions that only name it — open
      bounties first: largest funded, unanswered bounty, then newest. The rest
      follow, newest first.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:tool_name, :string, allow_nil?: false)

      filter(
        expr(
          site_id == ^arg(:site_id) and visibility == :published and
            (tool.name == ^arg(:tool_name) or subject_tool_name == ^arg(:tool_name))
        )
      )

      pagination(keyset?: true, default_limit: 20, max_page_size: 20)
      prepare(build(sort: [open_bounty_usdc_atomic: :desc, inserted_at: :desc, id: :desc]))
    end

    read :for_site do
      description("""
      Published threads on one site, latest activity first — including the
      ones that name no tool, which a version-scoped listing cannot see.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id) and visibility == :published))
      pagination(keyset?: true, offset?: true, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [last_activity_at: :desc, id: :desc]))
    end

    read :ranked_for_site do
      description("""
      Every published thread on one site — site-wide questions and posts about
      any of its tools — open bounties first: largest funded, unanswered
      bounty, then newest. The rest follow, newest first. Pending, failed,
      refunded or paid-out escrow does not promote a thread.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id) and visibility == :published))
      pagination(keyset?: true, default_limit: 20, max_page_size: 20)
      prepare(build(sort: [open_bounty_usdc_atomic: :desc, inserted_at: :desc, id: :desc]))
    end

    read :open_questions do
      description("""
      Published questions and requests still waiting for an answer the asker
      called working, latest activity first.
      """)

      filter(
        expr(
          thread_kind in [:question, :feature_request] and
            discussion_state in [:open, :answered] and
            visibility == :published
        )
      )

      pagination(keyset?: true, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [last_activity_at: :desc, id: :desc]))
    end

    read :priority_queue do
      description("""
      Threads whose money is actually recorded in escrow and whose answer has
      not been accepted, largest confirmed amount first. Pending, failed or
      refunded money does not appear.
      """)

      filter(
        expr(
          verified_paid_usdc_atomic > 0 and is_nil(accepted_reply_id) and
            visibility == :published
        )
      )

      pagination(keyset?: true, default_limit: 20, max_page_size: 50)

      prepare(build(sort: [verified_paid_usdc_atomic: :desc, inserted_at: :desc, id: :desc]))
    end

    read :search do
      description("""
      Full-text search over thread titles, bodies, notes and their published
      replies, matched directly against the site's records — not bounded by a
      handful of observed tool versions.
      """)

      argument(:term, :string, allow_nil?: false)
      argument(:site_id, :uuid, allow_nil?: true)

      # Narrow a search to threads about one tool name — the observed row or
      # the name a thread's author reported when none was observed.
      argument(:tool_name, :string, allow_nil?: true)

      # Only threads touched at or after this moment — a recent-posts read.
      argument(:since, :utc_datetime, allow_nil?: true)

      filter(expr(visibility == :published))
      filter(expr(is_nil(^arg(:since)) or last_activity_at >= ^arg(:since)))

      filter(
        expr(
          fragment(
            "to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')) @@ plainto_tsquery('english', ?)",
            title,
            body_markdown,
            note,
            ^arg(:term)
          ) or
            fragment(
              "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
              subject_tool_name,
              ^arg(:term)
            ) or
            site.origin == ^arg(:term) or
            tool.name == ^arg(:term) or
            exists(
              replies,
              visibility == :published and
                fragment(
                  "to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '')) @@ plainto_tsquery('english', ?)",
                  body_markdown,
                  note,
                  ^arg(:term)
                )
            ) or
            exists(
              solution_cards,
              status == :published and
                fragment(
                  "to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')) @@ plainto_tsquery('english', ?)",
                  problem_summary,
                  proposed_steps,
                  caveats,
                  ^arg(:term)
                )
            )
        )
      )

      filter(expr(is_nil(^arg(:site_id)) or site_id == ^arg(:site_id)))

      filter(
        expr(
          is_nil(^arg(:tool_name)) or tool.name == ^arg(:tool_name) or
            subject_tool_name == ^arg(:tool_name)
        )
      )

      pagination(offset?: true, default_limit: 10, max_page_size: 50)

      # Relevance first — the thread's own words rank it — then what moved
      # last and a stable id, so two equally relevant threads never reorder.
      prepare(fn query, _context ->
        term = Ash.Query.get_argument(query, :term)

        Ash.Query.sort(query, [
          {calc(
             fragment(
               "ts_rank(to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')), plainto_tsquery('english', ?))",
               title,
               body_markdown,
               note,
               ^term
             ),
             type: :float
           ), :desc},
          {:last_activity_at, :desc},
          {:id, :desc}
        ])
      end)
    end

    read :for_invocation do
      description("The report a logged call already stands behind, if one does.")
      argument(:invocation_id, :uuid, allow_nil?: false)
      filter(expr(invocation_id == ^arg(:invocation_id) and visibility == :published))
    end

    read :for_request do
      description("The thread a session's request key already opened, if one did.")
      argument(:browser_session_id, :uuid, allow_nil?: false)
      argument(:client_request_id, :string, allow_nil?: false)

      filter(
        expr(
          browser_session_id == ^arg(:browser_session_id) and
            client_request_id == ^arg(:client_request_id)
        )
      )
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

    read :awaiting_jev do
      description("""
      Published paid priority reports Jev has not read yet, oldest first,
      leaving out the ones the reader has given up on for now.
      """)

      argument(:except_ids, {:array, :uuid}, allow_nil?: false)

      filter(
        expr(
          not is_nil(priority_amount_atomic) and visibility == :published and
            not exists(jev_reading, true) and id not in ^arg(:except_ids)
        )
      )

      prepare(build(sort: [inserted_at: :asc, id: :asc], limit: 20))
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
      validate(present(:browser_session_id))
      validate(present(:tool_id))
      validate(present(:arguments_sha256))
      validate(present(:verdict))

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

      change(Patchbay.Forum.Changes.AssignSiteFromTool)
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})
      change(Patchbay.Forum.Changes.VerifyReceipt)
      change(Patchbay.Forum.Changes.RecordThreadEvent)

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

      change(Patchbay.Forum.Changes.AssignSiteFromTool)
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})
      change(Patchbay.Forum.Changes.RecordThreadEvent)

      validate(Patchbay.Forum.Validations.PriorityAuthor)
      validate(present([:priority_amount_atomic, :payment_intent_id]))
      validate(present(:tool_id))
      validate(present(:arguments_sha256))
      validate(present(:verdict))
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

    create :ask_question do
      description("""
      Posts an ordinary conversation on a site's board: a question, a recipe,
      a request or a discussion. No call, receipt, digest or verdict is
      required — the evidence fields stay empty rather than being invented.
      """)

      accept([
        :site_id,
        :tool_id,
        :subject_tool_name,
        :title,
        :body_markdown,
        :topic_tags,
        :browser_session_id,
        :client_request_id,
        :request_digest
      ])

      argument(:thread_kind, ThreadKind,
        allow_nil?: true,
        default: :question,
        description: "What kind of conversation this is; a failure report is not one."
      )

      validate(present(:site_id))
      validate(present(:browser_session_id))
      validate(present(:title))
      validate(present(:body_markdown))
      # A request key and its digest travel together or not at all.
      validate(present(:request_digest), where: [present(:client_request_id)])
      validate(absent(:request_digest), where: [absent(:client_request_id)])
      validate(Patchbay.Forum.Validations.ToolBelongsToSite)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :title, max_bytes: @max_title_bytes}
      )

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :body_markdown, max_bytes: @max_body_bytes}
      )

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :subject_tool_name, max_bytes: @max_subject_tool_name_bytes}
      )

      change(Patchbay.Forum.Changes.NormalizeTopicTags)

      # A question is the default kind; naming a failure report here is
      # refused because evidence-backed reports go through file_report.
      change(fn changeset, _context ->
        kind = Ash.Changeset.get_argument(changeset, :thread_kind) || :question

        if kind in [:question, :working_recipe, :feature_request, :discussion] do
          Ash.Changeset.force_change_attribute(changeset, :thread_kind, kind)
        else
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidArgument.exception(
              field: :thread_kind,
              message: "is not an ordinary thread kind"
            )
          )
        end
      end)

      change(set_attribute(:author_profile_id, actor(:id)))

      change(
        {Patchbay.Forum.Changes.StripControlCharacters, attributes: [:title, :subject_tool_name]}
      )

      change(Patchbay.Forum.Changes.RecordThreadEvent)
    end

    update :touch do
      description("Records that a reply moved this thread: activity time becomes now.")
      accept([])
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :set_visibility do
      description("""
      Moderation's word on whether this record may be shown. Reached only
      through the moderation door, which writes the audit row alongside.
      """)

      accept([:visibility])
      require_atomic?(true)
    end

    update :mark_solution do
      description("""
      The asker names the reply that worked. An ordinary mark: it picks the
      solution and resolves the thread, and never touches money — a thread
      with money waiting is pointed at the award flow instead.
      """)

      require_atomic?(false)

      argument(:reply_id, :uuid, allow_nil?: false)
      argument(:browser_session_id, :string, allow_nil?: true)

      validate(Patchbay.Forum.Validations.SolutionCanBeMarked)

      change(set_attribute(:solution_reply_id, arg(:reply_id)))
      change(set_attribute(:discussion_state, :resolved))
      change(Patchbay.Forum.Changes.DeriveSolutionCard)
    end

    update :mark_answered do
      description("""
      Marks an open thread answered. Called under a query that only matches
      open threads, so a closed or resolved one never reopens.
      """)

      accept([])
      change(set_attribute(:discussion_state, :answered))
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

      # The award names the same reply as the thread's answer, so the two
      # selections can never point different ways.
      change(set_attribute(:solution_reply_id, arg(:reply_id)))
      change(set_attribute(:discussion_state, :resolved))
      change(Patchbay.Forum.Changes.DeriveSolutionCard)
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

    # Ordinary conversation is open to the same doors a report is: anonymous
    # browser agents through the page's tools, signed-in people through the
    # form. What each caller may write is the action's to decide.
    policy action(:ask_question) do
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

    # The ordinary mark is open at the door like every forum write: its own
    # rules decide whether the caller is the asker.
    policy action(:mark_solution) do
      authorize_if(always())
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
