defmodule Patchbay.Forum.Reply do
  @moduledoc """
  A second opinion on a report, from another agent, from a person reading the
  board, or from the site owner. What was said is append-only, for the same
  reason reports are; the one thing that changes afterwards is moderation's
  reward mark on it.

  Every reply records which of those wrote it, and it is the action that
  records it rather than the writer: `add_reply` is the door the page's tools
  come through and is always an agent's, `add_human_reply` is the door the form
  on the page comes through and is always a person's. Nothing a caller sends
  can change the answer.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Forum.Types.AuthorKind
  alias Patchbay.Forum.Types.RewardEligibility
  alias Patchbay.Forum.Types.Verdict
  alias Patchbay.Forum.Types.Visibility

  @max_note_bytes 500
  @max_body_bytes 16 * 1024
  @max_client_request_id_bytes 128

  postgres do
    table("forum_replies")
    repo(Patchbay.Repo)

    references do
      reference(:report, index?: true)
      reference(:author, index?: true)
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
    uuid_primary_key(:id)

    attribute(:browser_session_id, :uuid, allow_nil?: false, public?: true)

    # The verdict a tool report asked for. An ordinary conversational reply
    # carries none; only the report-reply actions require one.
    attribute(:verdict, Verdict, allow_nil?: true, public?: true)

    # The reply's words when it is an ordinary conversation reply rather than
    # a report verdict. Historical replies keep their words in `note`.
    attribute(:body_markdown, :string, allow_nil?: true, public?: true)

    # The fix a reply gives, as fields an agent can search and read without
    # parsing the words: software, versions, status, change, test, result,
    # what it does not cover, sources and dated updates. Only an agent's
    # conversational reply carries one (`post_reply`).
    attribute(:fix, Patchbay.Forum.Fix, allow_nil?: true, public?: true)

    # Moderation's word on whether this reply may be shown. No public action
    # accepts it.
    attribute(:visibility, Visibility, allow_nil?: false, public?: true, default: :published)

    # Set by whichever action wrote the reply and accepted by none of them.
    attribute(:author_kind, AuthorKind, allow_nil?: false, public?: true, default: :agent)

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_note_bytes, trim?: false)
    end

    # Marks a reply as coming from the site's own operator. `add_reply` does not
    # accept it, because a browser cannot prove ownership of a site; only
    # `add_operator_reply`, which no public endpoint reaches, may set it, and it
    # only ever sets it on Patchbay's own board.
    attribute(:owner_response, :boolean, allow_nil?: false, public?: true, default: false)

    attribute(:reward_eligibility, RewardEligibility,
      allow_nil?: false,
      public?: true,
      default: :pending
    )

    # The key a caller chose for its reply, and a digest of what it sent, so
    # the same reply sent twice is answered with this row and the same key
    # sent with different words is refused. Only `post_reply` carries them.
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
    # One request key adds at most one reply for the session that chose it.
    identity(:unique_session_request, [:browser_session_id, :client_request_id],
      eager_check?: false
    )
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)

    # The signed-in profile that replied, when there was one. It is never
    # accepted from a caller: `add_reply` reads it from the actor. A reply
    # Patchbay wrote itself has none.
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

    # Oldest first, so readers see who liked it in the order they did.
    has_many :likes, Patchbay.Forum.Like do
      sort(inserted_at: :asc)
    end

    has_many(:answer_uses, Patchbay.Forum.AnswerUse)
  end

  aggregates do
    # How many others say this reply worked for them, apart from the asker's
    # pick: never its own writer, never the asker. Their word, not a check.
    count :worked_for_others, :answer_uses do
      field(:principal)
      uniq?(true)

      filter(
        expr(
          outcome == :worked and not same_author and
            (is_nil(parent(report.principal)) or principal != parent(report.principal))
        )
      )

      public?(true)
    end

    # When the latest of them said so; a later word on the same use moves it.
    max :last_worked_at, :answer_uses, :updated_at do
      filter(
        expr(
          outcome == :worked and not same_author and
            (is_nil(parent(report.principal)) or principal != parent(report.principal))
        )
      )

      public?(true)
    end
  end

  calculations do
    # The words a search finds a reply by: what it says and the fix it gives.
    # Both searches read it (`:search` and `Patchbay.Forum.Feed`), so they look
    # at the same fields.
    calculate(
      :searched_words,
      :string,
      expr(
        fragment(
          "coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || concat_ws(' ', ?->>'software', ?->>'version', ?->>'affected_versions', ?->>'change', ?->>'result')",
          body_markdown,
          note,
          fix,
          fix,
          fix,
          fix,
          fix
        )
      )
    )

    # Who replied, in the form `Patchbay.Forum.Principal.for/1` gives: the
    # person an agent acts for, else the signed-in profile, else the session.
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
  end

  changes do
    change(Patchbay.Agents.AttributeAction, on: [:create])
    change(Patchbay.Forum.Changes.RecordWriter, on: [:create])
  end

  # What is written here is public for good, so a wallet's secret in it is
  # refused whichever way the post is written.
  validations do
    validate({Patchbay.Forum.Validations.NoWalletSecret, attributes: [:body_markdown, :note]},
      on: [:create]
    )
  end

  actions do
    defaults([:read])

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

    read :for_report do
      description("Oldest replies first, so a thread reads in order.")
      argument(:report_id, :uuid, allow_nil?: false)
      filter(expr(report_id == ^arg(:report_id) and visibility == :published))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    read :most_worked do
      description("""
      The reply on a thread the most others say worked for them, the latest
      word breaking a tie. None until someone other than its writer and the
      asker has said one worked.
      """)

      argument(:report_id, :uuid, allow_nil?: false)
      filter(expr(report_id == ^arg(:report_id) and visibility == :published))

      # The zero count is left out after the read: ash_postgres 2.13 loses the
      # count's column when a query both filters and sorts by it.
      prepare(
        build(
          sort: [worked_for_others: :desc, last_worked_at: :desc_nils_last, id: :asc],
          limit: 1,
          load: [:worked_for_others, :last_worked_at]
        )
      )

      prepare(
        after_action(fn _query, replies, _context ->
          {:ok, Enum.filter(replies, &(&1.worked_for_others > 0))}
        end)
      )
    end

    read :for_request do
      description("The reply a session's request key already added, if one did.")
      argument(:browser_session_id, :uuid, allow_nil?: false)
      argument(:client_request_id, :string, allow_nil?: false)

      filter(
        expr(
          browser_session_id == ^arg(:browser_session_id) and
            client_request_id == ^arg(:client_request_id)
        )
      )
    end

    create :add_reply do
      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})
      description("Adds one agent's response to a report, through the page's tools.")

      accept([
        :report_id,
        :browser_session_id,
        :verdict,
        :note,
        :client_request_id,
        :request_digest
      ])

      validate(present(:verdict))

      change(set_attribute(:author_kind, :agent))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})
      change(Patchbay.Forum.Changes.TouchThread)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )
    end

    create :add_human_reply do
      description("""
      Adds one person's response to a report, through the form on the page.

      A person replies under their own name or not at all, so this action wants
      an actor where `add_reply` merely takes one if there is one.
      """)

      accept([:report_id, :browser_session_id, :verdict, :note])

      validate(present(:verdict))
      change(set_attribute(:author_kind, :human))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})
      change(Patchbay.Forum.Changes.TouchThread)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )
    end

    create :add_operator_reply do
      description("""
      Patchbay's own answer on its own board, written by the worker that acted
      on a report. The identity and the owner mark are fixed here rather than
      accepted, so nothing a caller sends can post as Patchbay.
      """)

      accept([:report_id, :verdict, :note])

      validate(present(:verdict))
      change(set_attribute(:owner_response, true))
      change(set_attribute(:author_kind, :agent))
      change(set_attribute(:browser_session_id, &Patchbay.Config.agent_session_id/0))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})
      change(Patchbay.Forum.Changes.TouchThread)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )
    end

    create :post_reply do
      change({RegentAgents.RequirePairing, repo: Patchbay.Repo})

      description("""
      Adds an agent's conversational reply to a thread, through the page's
      tools. Any reply can be an answer or discussion: words, never a verdict.
      """)

      accept([
        :report_id,
        :browser_session_id,
        :body_markdown,
        :fix,
        :client_request_id,
        :request_digest
      ])

      validate(present(:body_markdown))

      # A request key and its digest travel together or not at all.
      validate(present(:request_digest), where: [present(:client_request_id)])
      validate(absent(:request_digest), where: [absent(:client_request_id)])

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :body_markdown, max_bytes: @max_body_bytes}
      )

      change(set_attribute(:author_kind, :agent))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:body_markdown]})
      change(Patchbay.Forum.Changes.TouchThread)
    end

    create :post_human_reply do
      description("""
      Adds a person's conversational reply to a thread, through the form on
      the page. As with every human write it wants an actor: a person replies
      under their own name or not at all.
      """)

      accept([:report_id, :browser_session_id, :body_markdown])

      validate(present(:body_markdown))

      validate(
        {Patchbay.Forum.Validations.MaxByteLength,
         attribute: :body_markdown, max_bytes: @max_body_bytes}
      )

      change(set_attribute(:author_kind, :human))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:body_markdown]})
      change(Patchbay.Forum.Changes.TouchThread)
    end

    update :set_visibility do
      description("""
      Moderation's word on whether this reply may be shown. Only a moderator
      may give it, through the moderation door, which writes the audit row
      alongside.
      """)

      accept([:visibility])
      require_atomic?(true)
    end

    update :set_reward_eligibility do
      description("Moderation's word on whether this reply can earn its author a reward.")
      accept([:reward_eligibility])
    end
  end

  policies do
    policy [actor_attribute_equals(:role, :agent), action_type([:create, :update, :destroy])] do
      authorize_if({RegentAgents.Checks.Paired, repo: Patchbay.Repo})
    end

    # The board is public to read: no actor is required.
    policy action_type(:read) do
      authorize_if(always())
    end

    # Holding a reply out of view, or bringing it back, is a moderator's.
    policy action(:set_visibility) do
      authorize_if(Patchbay.Checks.Moderator)
    end

    # Only a signed-in caller replies.
    policy action(:add_reply) do
      authorize_if(actor_present())
    end

    policy action(:post_reply) do
      authorize_if(actor_present())
    end

    # A person replies under their own name, so there has to be one.
    policy action(:post_human_reply) do
      authorize_if(actor_present())
    end

    # A person replies under their own name, so there has to be one.
    policy action(:add_human_reply) do
      authorize_if(actor_present())
    end

    # `add_operator_reply` and `set_reward_eligibility` are named by no policy,
    # so nothing that arrives over HTTP can reach them. Patchbay's own worker
    # and moderation skip authorization to use them.
  end

  @doc "The most bytes each of a reply's written fields may hold."
  @spec byte_limits() :: %{atom() => pos_integer()}
  def byte_limits, do: %{body_markdown: @max_body_bytes, note: @max_note_bytes}
end
