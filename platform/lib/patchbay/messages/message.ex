defmodule Patchbay.Messages.Message do
  @moduledoc """
  One message left for Patchbay's team under a `topic` the site names, such as
  `agents`: its text, where the sender wants an answer (`reply_to`) and who
  left it. A signed-in person or their paired agent leaves one, a few an hour
  at most from each person and from each network (`:message` and
  `:message_address` in `Patchbay.Limits`). The sender is the actor, never an
  input (`SetSender`). Only Patchbay's moderators read messages
  (`Patchbay.Checks.Moderator`); the sender gets a receipt, `receipt/1`, and
  never reads them back.

  An agent's message carries the `operation_id` the agent made for it, and one
  agent uses an `operation_id` once (`AgentLeave`).
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Messages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Limits.LimitWrites
  alias Patchbay.Messages.Message.{AgentLeave, SetSender}

  @topic [max_length: 40, match: ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/]
  @shown_text "Use letters, numbers and marks you can see."
  @quickly "You've left a lot of messages this hour. Try again later."

  postgres do
    table("left_messages")
    repo(Patchbay.Repo)

    custom_indexes do
      index([:inserted_at, :id])
    end

    references do
      reference(:person, index?: true)
    end
  end

  actions do
    defaults([:read])

    read :newest do
      description("The team's inbox, newest first, a page at a time.")
      prepare(build(sort: [inserted_at: :desc, id: :desc], load: [:person, :agent]))
      pagination(keyset?: true, default_limit: 50)
    end

    read :by_operation do
      description("The message an agent left under one of its operation_ids, if it left one.")
      get?(true)
      argument(:agent_profile_id, :uuid, allow_nil?: false)
      argument(:operation_id, :uuid, allow_nil?: false)

      filter(
        expr(agent_profile_id == ^arg(:agent_profile_id) and operation_id == ^arg(:operation_id))
      )
    end

    create :leave do
      description("The actor leaves a message for the team.")
      accept([:topic, :body, :reply_to])
      # An agent's own key for this message, set by `AgentLeave` alone.
      argument(:operation_id, :uuid, public?: false)
      change(set_attribute(:operation_id, arg(:operation_id)))
      change(SetSender)
      validate(match(:body, RegentFormat.Text.pattern()), message: @shown_text)
      validate(match(:reply_to, RegentFormat.Name.pattern()), message: @shown_text)

      change(
        {LimitWrites,
         allowance: :message, address_allowance: :message_address, field: :body, message: @quickly}
      )
    end

    action :agent_leave, :map do
      description("An agent's message, its operation_id used once, as every surface answers it.")

      argument(:topic, :string, allow_nil?: false, constraints: @topic)
      argument(:body, :string, allow_nil?: false, constraints: [max_length: 2000])
      argument(:reply_to, :string, constraints: [max_length: 200])
      argument(:operation_id, :uuid, allow_nil?: false)

      run(AgentLeave)
    end
  end

  policies do
    # A paired agent, or a person signed in here whose profile is active.
    policy action(:leave) do
      authorize_if(actor_attribute_equals(:role, :agent))
      forbid_unless(actor_attribute_equals(:status, :active))
      authorize_if(actor_attribute_equals(:authentication_origin, :privy))
    end

    policy action(:agent_leave) do
      authorize_if(actor_attribute_equals(:role, :agent))
    end

    # Patchbay's moderators on their team page; the site itself when it answers
    # a retried message with its receipt (`AgentLeave`).
    policy action_type(:read) do
      authorize_if(Patchbay.Checks.Moderator)
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  attributes do
    uuid_primary_key(:id)

    # A short name the site gives the place it was left from, such as agents.
    attribute(:topic, :string, allow_nil?: false, public?: true, constraints: @topic)

    attribute(:body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 2000]
    )

    # Where the sender wants an answer, in their own words.
    attribute(:reply_to, :string, public?: true, constraints: [max_length: 200])
    attribute(:operation_id, :uuid)
    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    # The person it was left by, or the person whose paired agent left it.
    belongs_to(:person, Patchbay.Identity.AgentProfile,
      source_attribute: :person_profile_id,
      allow_nil?: false,
      public?: true
    )

    # The agent that left it, when one did.
    belongs_to(:agent, Patchbay.Identity.AgentProfile,
      source_attribute: :agent_profile_id,
      public?: true
    )
  end

  identities do
    # One agent uses an operation_id once. A person's own message has neither.
    identity(:agent_operation, [:agent_profile_id, :operation_id])
  end

  @doc "What the sender is told once a message is left: its id, topic and time."
  @spec receipt(t()) :: %{id: Ecto.UUID.t(), topic: String.t(), inserted_at: DateTime.t()}
  def receipt(message),
    do: %{id: message.id, topic: message.topic, inserted_at: message.inserted_at}
end
