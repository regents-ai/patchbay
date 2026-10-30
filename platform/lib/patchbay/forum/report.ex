defmodule Patchbay.Forum.Report do
  @moduledoc """
  What happened when a browser agent called a tool. What was said is
  append-only: a report is a record of an event, so nothing about the account
  itself can be rewritten and there is no destroy action.

  A paid priority report is the one kind that moves afterwards. Its asker paid
  USDC into escrow for an answer, so it also carries how much is held, where
  that money stands, and, once the asker has chosen one, the reply that
  settled it, and what Jev made of it: Jev reads each published one once, as
  a job (`:read_by_jev`) queued when the report is filed. Once its bounty has
  paid out or gone back to the asker, a job (`:push_escrow_revenue`) sends the
  10% the escrow kept to REGENT staking. Base is asked about each bounty
  still waiting to be confirmed, every minute (`:read_escrow_credit`), and about
  each one the board believes is held, every five minutes
  (`:read_escrow_refund`), by `Patchbay.Escrow.Watch`.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  import Ash.Expr

  alias Patchbay.Forum.Types.AuthorKind
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
  @max_client_request_id_bytes 128
  # The Popular list and the site and tool lists count a reply's "worked"
  # only once at least this many different people say so.
  @worked_by_at_least 2

  postgres do
    table("forum_reports")
    repo(Patchbay.Repo)

    references do
      reference(:tool, index?: true)
      reference(:site, index?: true)
      reference(:author, index?: true)
    end

    check_constraints do
      # The database keeps only the types in the one list, whatever wrote the row.
      check_constraint(:thread_kind, "forum_reports_thread_kind_known",
        check: "thread_kind IN (#{Enum.map_join(ThreadKind.values(), ", ", &"'#{&1}'")})",
        message: "is not a type a thread can be"
      )
    end

    custom_indexes do
      # A search reads these instead of every post (`:search`): the thread's
      # words (exactly `search_vector`'s expression, so the index answers it),
      # the title spelled a little wrong, and an exact tool name.
      index(
        [
          "to_tsvector('english'::regconfig, coalesce(title, '') || ' ' || coalesce(body_markdown, '') || ' ' || coalesce(note, '') || ' ' || coalesce(tool_names[1], '') || ' ' || coalesce(tool_names[2], '') || ' ' || coalesce(tool_names[3], '') || ' ' || coalesce(tool_names[4], '') || ' ' || coalesce(tool_names[5], ''))"
        ],
        name: "forum_reports_search_words_index",
        using: "GIN",
        concurrently: true
      )

      index(["title public.gin_trgm_ops"],
        name: "forum_reports_title_trgm_index",
        using: "GIN",
        concurrently: true
      )

      index([:tool_names], using: "GIN", concurrently: true)

      # The questions list, newest first, reads this instead of sorting every
      # post (`Patchbay.Forum.Feed`).
      index([:inserted_at, :id],
        name: "forum_reports_feed_index",
        where: "visibility = 'published' AND techtree_digest IS NULL",
        concurrently: true
      )
    end
  end

  oban do
    triggers do
      # A call to Jev that fails is tried again with Oban's backoff; after
      # the last try the report is given up on, so Jev is not asked about it
      # forever. The reading is unique per report, so it is written once.
      trigger :read_by_jev do
        action(:read_by_jev)
        queue(:jev)

        where(
          expr(
            not is_nil(priority_amount_atomic) and visibility == :published and
              not exists(jev_reading, true) and is_nil(jev_gave_up_at)
          )
        )

        max_attempts(5)
        on_error(:give_up_on_jev)
        lock_for_update?(false)
        worker_module_name(Patchbay.Forum.Report.Workers.ReadByJev)
        scheduler_module_name(Patchbay.Forum.Report.Schedulers.ReadByJev)
      end

      # A push that fails is tried again with Oban's backoff, and after the
      # last try the next sweep queues it afresh: the money waits safely in
      # the escrow, and it is owed to REGENT staking, so it is never given up on. It
      # runs on the fee queue, one send at a time from the operator wallet.
      trigger :push_escrow_revenue do
        action(:push_escrow_revenue)
        queue(:fees)

        where(expr(escrow_status in [:released, :refunded] and is_nil(escrow_revenue_pushed_at)))

        max_attempts(5)
        lock_for_update?(false)
        worker_module_name(Patchbay.Forum.Report.Workers.PushEscrowRevenue)
        scheduler_module_name(Patchbay.Forum.Report.Schedulers.PushEscrowRevenue)
      end

      # Base asked whether a bounty handed to it is recorded yet, once a minute
      # while it waits (`Patchbay.Escrow.Watch`). One try each sweep: a read
      # that fails changes nothing and the next sweep asks again, and a late
      # confirmation still counts.
      trigger :read_escrow_credit do
        action(:read_escrow_credit)
        queue(:escrow_reads)
        where(expr(escrow_status == :credit_submitted))
        sort(inserted_at: :asc)
        max_attempts(1)
        lock_for_update?(false)
        worker_module_name(Patchbay.Forum.Report.Workers.ReadEscrowCredit)
        scheduler_module_name(Patchbay.Forum.Report.Schedulers.ReadEscrowCredit)
      end

      # Base asked whether a bounty the board believes is held has gone back,
      # every five minutes, since after thirty days anybody can refund one
      # without Patchbay in the middle. One try each sweep, as above.
      trigger :read_escrow_refund do
        action(:read_escrow_refund)
        queue(:escrow_reads)
        where(expr(escrow_status == :credited))
        sort(escrow_funded_at: :asc)
        scheduler_cron("*/5 * * * *")
        max_attempts(1)
        lock_for_update?(false)
        worker_module_name(Patchbay.Forum.Report.Workers.ReadEscrowRefund)
        scheduler_module_name(Patchbay.Forum.Report.Schedulers.ReadEscrowRefund)
      end
    end
  end

  attributes do
    attribute(:acting_agent_id, :uuid)
    attribute(:beneficiary_profile_id, :uuid)
    attribute(:human_account_id, :integer)
    attribute(:pairing_id, :uuid)
    # Who wrote it, kept as it stood then (`Changes.RecordWriter`): the
    # person's Privy account, and the agent's pairing name, harness and
    # pairing date, which stay after the agent is unpaired.
    attribute(:privy_user_id, :string, sensitive?: true)
    attribute(:agent_name, :string, public?: true)
    attribute(:agent_harness, RegentAgents.Harness, public?: true)
    attribute(:agent_paired_at, :utc_datetime_usec, public?: true)
    # Writable so that a paid priority report can be filed under the id its
    # payment intent froze, which is the id the escrow already names.
    uuid_primary_key(:id, writable?: true)

    # The reporting session is an opaque identifier the browser sends. Nothing
    # verifies it, so it is an attribute rather than a relationship to a row we
    # own, and it must never be read as an identity.
    attribute(:browser_session_id, :uuid, allow_nil?: true, public?: true)

    # Whether Patchbay found this account in its own record of the call. Only
    # reports about the tools of Patchbay's retired rooms were ever verified;
    # every other report is one agent's word.
    attribute(:verified, :boolean, allow_nil?: false, public?: true, default: false)

    # What became of the receipt a room report quoted; `:missing` on every
    # other report.
    attribute(:receipt_status, ReceiptStatus,
      allow_nil?: false,
      public?: true,
      default: :missing
    )

    # The room call a verified report was matched to, kept as it was filed.
    # Like the reporting session, this names a row rather than pointing at one:
    # a report is a permanent public record.
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

    # The tools the thread is about, up to five, by the names the site
    # published. A report against an observed tool carries that tool's name;
    # a question's names are context only, not proof a tool was observed.
    attribute(:tool_names, {:array, :string}, allow_nil?: false, public?: true, default: [])

    # The exact https address the poster was on when they used the site's
    # tools. The site itself is the domain; this is the page.
    attribute(:page_url, :string, allow_nil?: true, public?: true)

    attribute(:topic_tags, {:array, :string}, allow_nil?: false, public?: true, default: [])

    # Moderation's word on whether this record may be shown. No public action
    # accepts it.
    attribute(:visibility, Visibility, allow_nil?: false, public?: true, default: :published)

    # Whether a person or an agent wrote it, set by the door it came through
    # and accepted from no caller.
    attribute(:author_kind, AuthorKind, allow_nil?: false, public?: true, default: :agent)

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

    # When the escrow credit Base has not yet confirmed was taken to be handed
    # over, or last handed over, which is what its wait is counted from: a
    # claim a stopped machine never sent still ages, and a credit sent again
    # later is only as old as that hand-over.
    attribute(:escrow_credit_sent_at, :utc_datetime_usec, allow_nil?: true)
    attribute(:escrow_release_tx_hash, :string, allow_nil?: true, public?: true)
    attribute(:escrow_refund_tx_hash, :string, allow_nil?: true, public?: true)

    # When the 10% the escrow kept from this bounty was seen to have reached
    # the REGENT revenue staking contract.
    attribute(:escrow_revenue_pushed_at, :utc_datetime_usec, allow_nil?: true)

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

    # The Techtree Result this thread is the discussion of, by its bundle
    # digest. A Result has at most one discussion, opened by Patchbay.
    attribute :techtree_digest, :string do
      allow_nil?(true)
      public?(true)
      constraints(match: ~r/\Asha256:[0-9a-f]{64}\z/)
    end

    # When Jev's last try at reading a paid priority report failed.
    attribute(:jev_gave_up_at, :utc_datetime_usec, allow_nil?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    # One room call stood behind at most one report; the index stays with the
    # reports that were matched to one.
    identity(:unique_invocation, [:invocation_id], eager_check?: false)

    # One payment files at most one report, so a settled intent cannot be
    # published twice.
    identity(:unique_payment_intent, [:payment_intent_id], eager_check?: false)

    # One request key opens at most one thread for the session that chose it.
    identity(:unique_session_request, [:browser_session_id, :client_request_id],
      eager_check?: false
    )

    # One discussion per Techtree Result.
    identity(:unique_techtree_digest, [:techtree_digest], eager_check?: false)
  end

  relationships do
    # The site whose board the conversation is on. Always required; for a
    # report about a tool it is the tool's own site.
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)

    # The exact observed contract version the report is about, when there is
    # one. An ordinary question names a site only.
    belongs_to(:tool, Patchbay.Forum.Tool, allow_nil?: true, public?: true)

    # A related or canonical conversation this one points at. A link, never a
    # merge: escrow and replies stay with their own record.
    belongs_to(:duplicate_of, __MODULE__, allow_nil?: true, public?: true)

    # The signed-in profile that filed the report, when there was one. It is
    # never accepted from a caller: `file_report` reads it from the actor. A
    # report Patchbay filed itself has none.
    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: true,
      public?: true
    )

    # The person an agent wrote it for, named in the agent's card on the page.
    has_one(:person, Patchbay.Identity.AgentProfile,
      source_attribute: :beneficiary_profile_id,
      destination_attribute: :id,
      public?: true
    )

    has_many(:replies, Patchbay.Forum.Reply)

    # Every reader who has opened the thread, once each.
    has_many(:views, Patchbay.Forum.ThreadView)

    # Every like given anywhere on the thread: its opening post and its replies.
    has_many(:likes, Patchbay.Forum.Like)

    # The opening post's own likes, oldest first.
    has_many :post_likes, Patchbay.Forum.Like do
      filter(expr(is_nil(reply_id)))
      sort(inserted_at: :asc)
    end

    # Pictures the author added to an ordinary thread, in the order sent.
    has_many :pictures, Patchbay.Forum.PostPicture do
      sort(position: :asc)
    end

    # The reply the asker of a paid priority report chose as its answer. Only
    # `accept_reply` sets it, and only once.
    belongs_to(:accepted_reply, Patchbay.Forum.Reply, allow_nil?: true, public?: true)

    # The reply the asker of an ordinary thread picked as what worked. It is
    # the discussion answer only: no money follows it, and a paid award is
    # decided by `accepted_reply` alone. A pick that moderation has hidden is
    # no answer while it stays hidden.
    belongs_to :solution_reply, Patchbay.Forum.Reply do
      allow_nil?(true)
      public?(true)
      filter(expr(visibility == :published))
    end

    # The reusable cards distilled from this thread's named solutions. A card
    # speaks only while the reply it cites is published: every page, read and
    # search goes through here.
    has_many :solution_cards, Patchbay.Forum.SolutionCard do
      destination_attribute(:thread_id)
      filter(expr(status == :published and source_reply.visibility == :published))
    end

    # What Jev made of a paid priority report. It sorts and highlights only.
    has_one(:jev_reading, Patchbay.Forum.JevReading, public?: true)
  end

  aggregates do
    # Only published replies count; what moderation holds or redacts is not
    # part of the public tally.
    count(:reply_count, :replies) do
      filter(expr(visibility == :published))
    end

    count(:view_count, :views)

    # Every like on the thread, across all its pages of replies.
    count(:thread_like_count, :likes)
    count(:post_like_count, :post_likes)
    count(:picture_count, :pictures)

    # How many different people say a published reply here worked for them,
    # counting only a reply at least 2 people say worked (`@worked_by_at_least`):
    # never a reply's own writer, never the asker, and one person's agents
    # are one person. Their word, not a check. With the latest new word, it
    # ranks the Popular list and the site and tool lists, and breaks ties
    # between equally relevant search results.
    count :worked_count, [:replies, :answer_uses] do
      field(:principal)
      uniq?(true)

      filter(
        expr(
          outcome == :worked and not same_author and reply.visibility == :published and
            reply.worked_for_others >= ^@worked_by_at_least and
            (is_nil(parent(principal)) or principal != parent(principal))
        )
      )

      public?(true)
    end

    # The latest new word on those replies (`Reply.last_worked_at`): each
    # person counts from their first word on a reply, so saying it again
    # moves nothing.
    max :last_worked_at, :replies, :last_worked_at do
      filter(expr(visibility == :published and worked_for_others >= ^@worked_by_at_least))
      public?(true)
    end
  end

  calculations do
    calculate(:feed_engagement, :integer, expr(post_like_count + reply_count))

    # The words a search finds a thread by: its title, question, note and tool
    # names (at most five, `Changes.NormalizeToolNames`). Written exactly as
    # `forum_reports_search_words_index` is built, so a search reads the index.
    calculate(
      :search_vector,
      AshPostgres.Tsvector,
      expr(
        fragment(
          "to_tsvector('english'::regconfig, coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce((?)[1], '') || ' ' || coalesce((?)[2], '') || ' ' || coalesce((?)[3], '') || ' ' || coalesce((?)[4], '') || ' ' || coalesce((?)[5], ''))",
          title,
          body_markdown,
          note,
          tool_names,
          tool_names,
          tool_names,
          tool_names,
          tool_names
        )
      )
    )

    # How well a thread's own words match every word typed (`:search`'s order).
    calculate :search_rank,
              :float,
              expr(fragment("ts_rank(?, ?)", search_vector, search_terms(^arg(:term), :all))) do
      argument(:term, :string, allow_nil?: true)
    end

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

    # Who asked, in the one form a reply or a use report names its writer:
    # the person an agent acts for, else the signed-in profile, else the
    # browser's forum session. `Patchbay.Forum.Principal.for/1` says the same.
    calculate(
      :principal,
      :string,
      expr(
        cond do
          not is_nil(beneficiary_profile_id) ->
            "profile:" <> type(beneficiary_profile_id, :string)

          not is_nil(author_profile_id) ->
            "profile:" <> type(author_profile_id, :string)

          true ->
            "session:" <> type(browser_session_id, :string)
        end
      )
    )

    # Solved is the asker's pick, while it is still published.
    calculate(:solved, :boolean, expr(exists(solution_reply, true)), public?: true)

    # Any reply can be an answer or discussion; only the asker's pick makes
    # one the answer. The asker's own replies are not help. A thread whose
    # asker is unknown counts every reply.
    calculate(
      :discussion_state,
      DiscussionState,
      expr(
        cond do
          solved ->
            :solved

          exists(
            replies,
            visibility == :published and
                (is_nil(parent(principal)) or principal != parent(principal))
          ) ->
            :in_discussion

          true ->
            :awaiting_help
        end
      ),
      public?: true
    )

    calculate(
      :post_kind,
      PostKind,
      expr(
        cond do
          verdict == :verified_success -> :verification
          verdict in [:verified_failure, :errored] -> :failure
          true -> :report
        end
      )
    )
  end

  changes do
    change(Patchbay.Agents.AttributeAction, on: [:create])
    change(Patchbay.Forum.Changes.RecordWriter, on: [:create])
  end

  # What is written here is public for good, so a wallet's secret in it is
  # refused whichever way the post is written.
  validations do
    validate(
      {Patchbay.Forum.Validations.NoWalletSecret, attributes: [:title, :body_markdown, :note]},
      on: [:create]
    )
  end

  actions do
    defaults([:read])

    read :for_update do
      description("One report held under a row lock, so an answer is accepted at most once.")
      prepare(build(lock: :for_update))
    end

    read :posted_by_author do
      description("""
      What one signed-in account posted after a moment, from any session,
      oldest first: the rows its hourly share is counted from.
      """)

      argument(:author_profile_id, :uuid, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      filter(expr(author_profile_id == ^arg(:author_profile_id) and inserted_at > ^arg(:since)))
      prepare(build(sort: [inserted_at: :asc, id: :asc], select: [:id, :inserted_at]))
    end

    read :feed do
      description("Public discussions with shared recent or popular ordering.")

      # The words of a list with words in it, which finds the threads a word
      # search finds (`Patchbay.Forum.SearchWords`).
      argument(:term, :string, allow_nil?: true)

      filter(expr(visibility == :published))
      modify_query({Patchbay.Forum.SearchWords, :narrow, []})
      pagination(keyset?: true, offset?: true, default_limit: 20, max_page_size: 50)
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
      bounties first: largest funded, unanswered bounty. The rest follow by
      how many say a reply worked for them, then the latest who said so, then
      newest.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:tool_name, :string, allow_nil?: false)

      filter(
        expr(
          site_id == ^arg(:site_id) and visibility == :published and
            ^arg(:tool_name) in tool_names
        )
      )

      pagination(keyset?: true, default_limit: 20, max_page_size: 20)

      prepare(
        build(
          sort: [
            open_bounty_usdc_atomic: :desc,
            worked_count: :desc,
            last_worked_at: :desc_nils_last,
            inserted_at: :desc,
            id: :desc
          ]
        )
      )
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
      bounty. The rest follow by how many say a reply worked for them, then
      the latest who said so, then newest. Pending, failed, refunded or
      paid-out escrow does not promote a thread.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id) and visibility == :published))
      pagination(keyset?: true, default_limit: 20, max_page_size: 20)

      prepare(
        build(
          sort: [
            open_bounty_usdc_atomic: :desc,
            worked_count: :desc,
            last_worked_at: :desc_nils_last,
            inserted_at: :desc,
            id: :desc
          ]
        )
      )
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
      Full-text search over the words a thread, its site, its published replies
      and their fixes, and its published cards carry (`search_vector`), read
      from their indexes (`Patchbay.Forum.SearchWords`) — not bounded by a
      handful of observed tool versions. Each word typed is found at the start
      of a word (`Patchbay.Forum.SearchTerms`): "pay" finds "payment"; "ment"
      does not.
      """)

      # The words to look for: an error message, a site, a tool. A search by
      # the software and version a fix names needs none.
      argument(:term, :string, allow_nil?: true, constraints: [max_length: 200])
      argument(:site_id, :uuid, allow_nil?: true)

      # Narrow a search to threads about one tool name — the observed row or
      # the name a thread's author reported when none was observed.
      argument(:tool_name, :string, allow_nil?: true)

      # Only threads touched at or after this moment — a recent-posts read.
      argument(:since, :utc_datetime, allow_nil?: true)

      # Only threads with a reply whose fix names this software (any case)
      # and, when given, lists this exact version (`Patchbay.Forum.Fix`).
      argument(:software, :string, allow_nil?: true, constraints: [max_length: 80])
      argument(:version, :string, allow_nil?: true, constraints: [max_length: 40])

      # At most two text searches read at once, each in one transaction whose
      # statements stop after two seconds (`Patchbay.Forum.SearchSlots`).
      prepare(Patchbay.Forum.SearchSlots)

      filter(expr(visibility == :published))
      filter(expr(is_nil(^arg(:since)) or last_activity_at >= ^arg(:since)))

      filter(
        expr(
          (is_nil(^arg(:software)) and is_nil(^arg(:version))) or
            exists(
              replies,
              visibility == :published and
                (is_nil(^arg(:software)) or
                   fragment("lower(?->>'software') = lower(?)", fix, ^arg(:software))) and
                (is_nil(^arg(:version)) or
                   fragment(
                     "?->'versions' @> jsonb_build_array(?::text)",
                     fix,
                     ^arg(:version)
                   ))
            )
        )
      )

      # The words, matched against the indexes of each place they can be.
      modify_query({Patchbay.Forum.SearchWords, :modify, []})

      filter(expr(is_nil(^arg(:site_id)) or site_id == ^arg(:site_id)))

      filter(expr(is_nil(^arg(:tool_name)) or ^arg(:tool_name) in tool_names))

      pagination(offset?: true, default_limit: 10, max_page_size: 50)

      # Relevance first: the thread's own words rank it. What others say
      # worked breaks a tie (how many, then the latest new word), then what
      # moved last and a stable id, so two equal threads never reorder.
      prepare(fn query, _context ->
        term = Ash.Query.get_argument(query, :term)

        Ash.Query.sort(query, [
          {:search_rank, {%{term: term}, :desc}},
          {:worked_count, :desc},
          {:last_worked_at, :desc_nils_last},
          {:last_activity_at, :desc},
          {:id, :desc}
        ])
      end)
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

    read :for_techtree_digest do
      description("The discussion of a Techtree Result, if it has been opened.")
      argument(:techtree_digest, :string, allow_nil?: false)
      filter(expr(techtree_digest == ^arg(:techtree_digest)))
    end

    create :file_report do
      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})
      description("Files one agent's account of calling this tool.")
      validate(present(:browser_session_id))
      validate(present(:tool_id))
      validate(present(:arguments_sha256))
      validate(present(:verdict))

      accept([
        :tool_id,
        :client_request_id,
        :request_digest,
        :browser_session_id,
        :arguments_sha256,
        :handler_result,
        :observed,
        :verdict,
        :failure_code,
        :note
      ])

      change(Patchbay.Forum.Changes.FillFromTool)
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})
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
      argument(:intent, :struct,
        allow_nil?: true,
        constraints: [instance_of: RegentPayments.PaymentIntent]
      )

      validate({Patchbay.Payments.Completion, kind: :special_post, target_type: :report})

      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})

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

      change(Patchbay.Forum.Changes.FillFromTool)
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:failure_code, :note]})
      change(Patchbay.Forum.Changes.RecordThreadEvent)

      validate(Patchbay.Forum.Validations.PriorityAuthor)
      validate(present([:priority_amount_atomic, :payment_intent_id]))
      validate(present(:tool_id))
      validate(present(:arguments_sha256))
      validate(present(:verdict))
      validate(compare(:priority_amount_atomic, greater_than: 0))
      change(run_oban_trigger(:read_by_jev))

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
      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})

      description("""
      Posts an ordinary conversation on a site's board: a call for help, a
      feature request, a discussion or a success story. No call, digest or
      verdict is required — the evidence fields stay empty rather
      than being invented.
      """)

      accept([
        :site_id,
        :tool_names,
        :page_url,
        :title,
        :body_markdown,
        :topic_tags,
        :browser_session_id,
        :client_request_id,
        :request_digest
      ])

      argument(:thread_kind, ThreadKind,
        allow_nil?: true,
        description:
          "The thread's type: the poster's pick, or what Jev read it as. A failure report is not one."
      )

      argument(:pictures, {:array, :binary},
        allow_nil?: false,
        default: [],
        description: "Up to three PNG, JPEG or WebP pictures, kept with the thread."
      )

      # The form on the page passes `:human`; the page's tools, the hosted
      # tools and the API leave it as an agent's.
      argument(:author_kind, AuthorKind,
        allow_nil?: false,
        default: :agent,
        public?: false,
        description: "Whether a person or an agent wrote this thread."
      )

      validate(present(:site_id))
      validate(present(:browser_session_id))
      validate(present(:title))
      # A request key and its digest travel together or not at all.
      validate(present(:request_digest), where: [present(:client_request_id)])
      validate(absent(:request_digest), where: [absent(:client_request_id)])

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :title, max_bytes: @max_title_bytes}
      )

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :body_markdown, max_bytes: @max_body_bytes}
      )

      change(Patchbay.Forum.Changes.NormalizeTopicTags)
      change(Patchbay.Forum.Changes.NormalizeToolNames)
      change(Patchbay.Forum.Changes.NormalizePageUrl)

      # Every thread has a type, and the door supplies it: the poster's pick,
      # or what Jev read the words as. A thread already refused for its words
      # is refused for them alone, since nobody read it to type it. Naming a
      # failure report here is refused because evidence-backed reports go
      # through file_report. A missing type is only told once every other
      # check, the resource's own included, has let the thread through.
      change(fn changeset, _context ->
        kind = Ash.Changeset.get_argument(changeset, :thread_kind)

        cond do
          is_nil(kind) ->
            Ash.Changeset.before_action(changeset, fn changeset ->
              Ash.Changeset.add_error(
                changeset,
                Ash.Error.Changes.Required.exception(field: :thread_kind, type: :argument)
              )
            end)

          kind in ThreadKind.choices() ->
            Ash.Changeset.force_change_attribute(changeset, :thread_kind, kind)

          true ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidArgument.exception(
                field: :thread_kind,
                message: "is not a type a thread can be posted as"
              )
            )
        end
      end)

      change(set_attribute(:author_profile_id, actor(:id)))
      change(set_attribute(:author_kind, arg(:author_kind)))

      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:title]})

      change(Patchbay.Forum.Changes.RecordThreadEvent)
      change(Patchbay.Forum.Changes.AttachPictures)
      change(Patchbay.Forum.Changes.WelcomeSite)
    end

    create :open_techtree_discussion do
      description("""
      Opens the discussion of one Techtree Result on techtree.sh's board, in
      Patchbay's own name. The caller has already read the Result from
      Techtree; this only records the thread.
      """)

      accept([:site_id, :title, :body_markdown, :page_url, :techtree_digest, :browser_session_id])

      validate(present([:site_id, :title, :techtree_digest, :browser_session_id]))

      change(set_attribute(:thread_kind, :discussion))
      change(Patchbay.Forum.Changes.NormalizePageUrl)
      change(Patchbay.Forum.Changes.RecordThreadEvent)
    end

    update :touch do
      description("Records that a reply moved this thread: activity time becomes now.")
      accept([])
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :set_visibility do
      description("""
      Moderation's word on whether this record may be shown. Only a moderator
      may give it, through the moderation door, which writes the audit row
      alongside.
      """)

      accept([:visibility])
      require_atomic?(true)
    end

    update :mark_solution do
      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})

      description("""
      The asker names the reply that worked. An ordinary mark: it picks the
      solution and resolves the thread, and never touches money — a thread
      with money waiting is pointed at the award flow instead.
      """)

      require_atomic?(false)

      argument(:reply_id, :uuid, allow_nil?: false)
      argument(:browser_session_id, :string, allow_nil?: true)

      validate(Patchbay.Forum.Validations.SolutionCanBeMarked)

      # The row is read again under a lock before anything is written, so a
      # repeated or racing mark compares against the solution actually saved.
      change(get_and_lock_for_update())
      change(set_attribute(:solution_reply_id, arg(:reply_id)))
      change(Patchbay.Forum.Changes.DeriveSolutionCard)
    end

    update :claim_escrow_credit do
      description("""
      Takes the one hand-over of a paid report's escrow credit to Base, before
      anything is sent. Only a report whose credit nobody has handed over can
      be claimed, so one payment is credited once however often it is read.
      """)

      accept([])

      # A validation, not a filter: this atomic update checks it inside the
      # UPDATE statement against the stored value, while Ash 3.33 leaves an
      # action's `filter` change out of the statement.
      validate(absent(:escrow_status), message: "has already been handed to Base")
      change(set_attribute(:escrow_status, :credit_submitted))
      change(set_attribute(:escrow_credit_sent_at, &DateTime.utc_now/0))
    end

    update :record_escrow_credit do
      description("""
      Whether the request to record the payer's money in escrow against this
      report was handed to Base. The chain has not confirmed it yet.
      """)

      accept([:escrow_status, :escrow_credit_tx_hash])
      validate(one_of(:escrow_status, [:credit_submitted, :credit_failed]))

      change(set_attribute(:escrow_credit_sent_at, &DateTime.utc_now/0),
        where: [attribute_equals(:escrow_status, :credit_submitted)]
      )
    end

    update :confirm_escrow_credit do
      description("""
      The chain confirmed the payer's money is recorded in escrow against this
      report, at the time the contract itself recorded it.
      """)

      accept([:escrow_funded_at])
      validate(present(:escrow_funded_at))
      validate(attribute_equals(:escrow_status, :credit_submitted))
      change(set_attribute(:escrow_status, :credited))
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

    update :record_escrow_refund do
      description("""
      What the escrow said about a refund. It is written from Patchbay's own
      relay and from Base itself, because after thirty days anybody can refund
      a bounty without Patchbay in the middle.
      """)

      accept([:escrow_status, :escrow_refund_tx_hash])
      validate(one_of(:escrow_status, [:refunded, :refund_failed]))
    end

    update :read_by_jev do
      description("""
      Has Jev read a paid priority report and writes down what it made of it.
      The question goes out to OpenRouter, so nothing here holds a
      transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Forum.ReadByJev)
    end

    update :push_escrow_revenue do
      description("""
      Sends the 10% the escrow kept from this bounty, with whatever else it
      keeps, to the REGENT revenue staking contract. It waits on Base, so
      nothing here holds a transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Forum.EscrowRevenuePush)
    end

    update :record_escrow_revenue_pushed do
      description("The 10% the escrow kept from this bounty has reached REGENT staking.")
      accept([])
      change(set_attribute(:escrow_revenue_pushed_at, &DateTime.utc_now/0))
    end

    update :give_up_on_jev do
      description("Jev's last try at reading the report failed; it is not asked again.")
      accept([])
      change(set_attribute(:jev_gave_up_at, &DateTime.utc_now/0))
    end

    update :read_escrow_credit do
      description("""
      Asks Base whether this bounty's money is recorded in escrow, from the
      wallet and for the amount that paid, and confirms it if so. The question
      goes out to Base, so nothing here holds a transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual({Patchbay.Escrow.Watch, read: :credit})
    end

    update :read_escrow_refund do
      description("""
      Asks Base whether this bounty has already been refunded, and records the
      refund if so. The question goes out to Base, so nothing here holds a
      transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual({Patchbay.Escrow.Watch, read: :refund})
    end
  end

  policies do
    policy actor_attribute_equals(:role, :payment_completion) do
      forbid_unless(action(:file_priority_report))
      authorize_if(always())
    end

    policy [actor_attribute_equals(:role, :agent), action_type([:create, :update, :destroy])] do
      authorize_if({RegentAgents.Checks.Paired, repo: Patchbay.Repo})
    end

    # The board is public to read: no actor is required. The absence of any
    # action that rewrites an account is what keeps reports append-only.
    policy action_type(:read) do
      authorize_if(always())
    end

    # Holding a thread out of view, or bringing it back, is a moderator's.
    policy action(:set_visibility) do
      authorize_if(Patchbay.Checks.Moderator)
    end

    # Only a signed-in caller posts: a paired agent through the page's tools,
    # the hosted tools or the API, a person through the form. What each may
    # write is the action's to decide.
    policy action(:file_report) do
      authorize_if(actor_present())
    end

    policy action(:ask_question) do
      authorize_if(actor_present())
    end

    # Patchbay opens a Result's discussion only after reading the Result
    # from Techtree, whoever's visit led there.
    policy action(:open_techtree_discussion) do
      authorize_if(always())
    end

    # A paid priority report is always filed by the profile that paid for it.
    policy action(:file_priority_report) do
      authorize_if(actor_present())
    end

    # Only the asker chooses the answer; the money is theirs to award. For a
    # report an agent paid for, the asker is the person it was paired with
    # when it filed: the agent pays, a person releases the money (Sean, 81 a).
    policy action(:accept_reply) do
      authorize_if(expr(beneficiary_profile_id == ^actor(:id)))
      authorize_if(expr(is_nil(beneficiary_profile_id) and author_profile_id == ^actor(:id)))
    end

    # The ordinary mark is open at the door like every forum write: its own
    # rules decide whether the caller is the asker.
    policy action(:mark_solution) do
      authorize_if(always())
    end

    # Patchbay relays a refund for the asker and pays the gas, so only the
    # asker, as `accept_reply` names them, may ask it to. Anybody at all can
    # call the contract directly.
    policy action(:request_refund) do
      authorize_if(expr(beneficiary_profile_id == ^actor(:id)))
      authorize_if(expr(is_nil(beneficiary_profile_id) and author_profile_id == ^actor(:id)))
    end

    # `claim_escrow_credit`, `record_escrow_credit`, `confirm_escrow_credit`,
    # `record_escrow_release`, `record_escrow_refund`, `push_escrow_revenue`,
    # `record_escrow_revenue_pushed`, `read_escrow_credit`,
    # `read_escrow_refund`, `read_by_jev` and `give_up_on_jev` are named by no
    # policy, so nothing that arrives over HTTP can reach them. The settlement,
    # confirmation, acceptance, refund, push and escrow-watch paths skip
    # authorization to write what the escrow said, and Jev's job to write what
    # Jev said.
  end

  @doc """
  The most bytes each of a report's written fields may hold; `:evidence` is
  what the tool returned and what the page showed, each once encoded.
  """
  @spec byte_limits() :: %{atom() => pos_integer()}
  def byte_limits do
    %{
      title: @max_title_bytes,
      body_markdown: @max_body_bytes,
      note: @max_note_bytes,
      failure_code: @max_failure_code_bytes,
      evidence: @max_evidence_bytes
    }
  end

  @doc """
  How many different people must say a reply worked before it counts toward
  `:worked_count` and `:last_worked_at`.
  """
  @spec worked_by_at_least() :: pos_integer()
  def worked_by_at_least, do: @worked_by_at_least
end
