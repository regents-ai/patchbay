defmodule Patchbay.Assist.ModelCall do
  @moduledoc """
  One question Patchbay sent a model on OpenRouter: Jev, or the model that
  drafts a tool's arguments. It is written before the question is sent, so
  the limits count questions still in flight as well as answered ones, and
  closed with the tokens and cost the provider said the answer took.

  Every write is Patchbay's own and says so by skipping authorization;
  `Patchbay.Assist.ModelCalls` holds the free help's look-ups to their
  daily limits before it opens one.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Assist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Assist.Types.ModelCallOutcome
  alias Patchbay.Assist.Types.ModelCallPurpose

  postgres do
    table("assist_model_calls")
    repo(Patchbay.Repo)

    references do
      reference(:assist_run, on_delete: :nilify)
    end

    custom_indexes do
      # The deployment's daily ceiling counts every question of the last day.
      index([:inserted_at])
      # The free help's limits count its own look-ups, and each connection's.
      index([:purpose, :visitor_key, :inserted_at])
      # A run's removal clears its questions' link to it.
      index([:assist_run_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:purpose, ModelCallPurpose, allow_nil?: false, public?: true)
    attribute(:model, :string, allow_nil?: false, public?: true)

    # The key the free help's connection is counted by, never the address.
    attribute(:visitor_key, :string, allow_nil?: true, public?: true)

    attribute(:outcome, ModelCallOutcome, allow_nil?: false, default: :asked, public?: true)

    # What the provider said the answer took, when it said.
    attribute(:prompt_tokens, :integer, allow_nil?: true, public?: true)
    attribute(:completion_tokens, :integer, allow_nil?: true, public?: true)
    attribute(:cost_usd, :decimal, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:assist_run, Patchbay.Assist.Run, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :ask do
      description("A question about to be sent, for a fix's run or a priority report.")
      accept([:purpose, :model, :assist_run_id])
    end

    create :ask_for_help do
      description("The free help's look at the known fixes, from one connection.")
      accept([:model, :visitor_key])
      validate(present(:visitor_key))
      change(set_attribute(:purpose, :known_fix_for_help))
    end

    update :answered do
      accept([:prompt_tokens, :completion_tokens, :cost_usd])
      change(set_attribute(:outcome, :answered))
    end

    update :failed do
      accept([])
      change(set_attribute(:outcome, :failed))
    end
  end

  policies do
    # No visitor reads or writes these; Patchbay's own work skips this.
    policy always() do
      forbid_if(always())
    end
  end
end
