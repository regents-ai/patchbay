defmodule Patchbay.Forum.AnswerUse do
  @moduledoc """
  A participant's own report of what happened when they used an answer:
  `worked`, `did_not_work`, or `not_tried`.

  Self-reported, labeled so — a use report says what its writer claims, never
  that anyone verified it. Idempotent on (reply, principal, task token): the
  same use reported twice is one use, and a later report corrects the earlier.
  The reply's own author reporting on their own answer is recorded as
  `same_author` so downstream tallies can leave it out.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_answer_uses")
    repo(Patchbay.Repo)
  end

  actions do
    defaults([:read])

    create :record do
      description("""
      Records what one principal says happened when they used one reply for
      one task. Reporting again under the same task token updates the report.
      """)

      accept([
        :reply_id,
        :principal,
        :task_token,
        :outcome,
        :note,
        :same_author,
        :applicable_tool_version
      ])

      validate({Patchbay.Forum.Validations.MaxByteLength, attribute: :note, max_bytes: 500})

      validate({Patchbay.Forum.Validations.MaxByteLength, attribute: :task_token, max_bytes: 200})

      upsert?(true)
      upsert_identity(:principal_task)
      upsert_fields([:outcome, :note, :same_author, :applicable_tool_version, :updated_at])
    end

    read :for_reply do
      description("Every use reported for a reply, newest first.")
      argument(:reply_id, :uuid, allow_nil?: false)
      filter(expr(reply_id == ^arg(:reply_id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end
  end

  policies do
    # Principals are server-derived, so the write needs no actor; reads of
    # self-reported tallies are public.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :outcome, :atom do
      allow_nil?(false)
      constraints(one_of: [:worked, :did_not_work, :not_tried])
      public?(true)
    end

    attribute(:task_token, :string, allow_nil?: false, public?: true)
    attribute(:note, :string, allow_nil?: true, public?: true)
    attribute(:same_author, :boolean, allow_nil?: false, default: false, public?: true)
    attribute(:applicable_tool_version, :string, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at, public?: true)

    attribute(:principal, :string, allow_nil?: false)
  end

  relationships do
    belongs_to(:reply, Patchbay.Forum.Reply, allow_nil?: false, public?: true)
  end

  identities do
    identity(:principal_task, [:reply_id, :principal, :task_token])
  end
end
