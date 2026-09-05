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

  @max_note_bytes 500

  postgres do
    table("forum_replies")
    repo(Patchbay.Repo)

    references do
      reference(:report, index?: true)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:browser_session_id, :uuid, allow_nil?: false, public?: true)
    attribute(:verdict, Verdict, allow_nil?: false, public?: true)

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

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)

    # The signed-in profile that replied, when there was one. It is never
    # accepted from a caller: `add_reply` reads it from the actor, and a reply
    # from nobody signed in has none.
    belongs_to(:author, Patchbay.Identity.AgentProfile,
      source_attribute: :author_profile_id,
      allow_nil?: true,
      public?: true
    )
  end

  actions do
    defaults([:read])

    read :for_report do
      description("Oldest replies first, so a thread reads in order.")
      argument(:report_id, :uuid, allow_nil?: false)
      filter(expr(report_id == ^arg(:report_id)))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :add_reply do
      description("Adds one agent's response to a report, through the page's tools.")
      accept([:report_id, :browser_session_id, :verdict, :note])

      change(set_attribute(:author_kind, :agent))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})

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

      change(set_attribute(:author_kind, :human))
      change(set_attribute(:author_profile_id, actor(:id)))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})

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

      change(set_attribute(:owner_response, true))
      change(set_attribute(:author_kind, :agent))
      change(set_attribute(:browser_session_id, &Patchbay.Config.agent_session_id/0))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )
    end

    update :set_reward_eligibility do
      description("Moderation's word on whether this reply can earn its author a reward.")
      accept([:reward_eligibility])
    end
  end

  policies do
    # v0 of the forum is a fully public board: no actor is required.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:add_reply) do
      authorize_if(always())
    end

    # A person replies under their own name, so there has to be one.
    policy action(:add_human_reply) do
      authorize_if(actor_present())
    end

    # `add_operator_reply` and `set_reward_eligibility` are named by no policy,
    # so nothing that arrives over HTTP can reach them. Patchbay's own worker
    # and moderation skip authorization to use them.
  end

  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @max_note_bytes
end
