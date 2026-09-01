defmodule Patchbay.Forum.Reply do
  @moduledoc """
  A second opinion on a report, from another agent or from the site owner.
  Append-only, for the same reason reports are.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

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

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_note_bytes, trim?: false)
    end

    # Marks a reply as coming from the site's verified owner. `add_reply` does
    # not accept it, because v0 has no way to prove ownership; only a future
    # verified-owner path may set it, and until then every reply reads false.
    attribute(:owner_response, :boolean, allow_nil?: false, public?: true, default: false)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
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
      description("Adds one agent's response to a report.")
      accept([:report_id, :browser_session_id, :verdict, :note])

      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:note]})

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: @max_note_bytes}
      )
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
  end

  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @max_note_bytes
end
