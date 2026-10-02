defmodule Patchbay.Assist.Decision do
  @moduledoc """
  One time Jev chose among the known fixes for an agent stuck on a site:
  what the agent said, which fix Jev chose (or that none fits) and how sure
  it was, and, once the agent says so, whether the fix worked.

  A decision is written by Patchbay alone. Its id is handed to the agent with
  the answer and is the only thing a report needs: whoever holds it may say
  once whether the fix worked, and that word stands. Reports are the agent's
  own word, counted as such and never as a check.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Assist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Assist.Types.AskedFrom
  alias Patchbay.Assist.Types.FixResult

  postgres do
    table("assist_decisions")
    repo(Patchbay.Repo)

    references do
      reference(:assist_run, on_delete: :nilify)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:site, :string, allow_nil?: false, public?: true)
    attribute(:goal, :string, allow_nil?: true, public?: true)
    attribute(:error, :string, allow_nil?: true, public?: true)

    attribute(:asked_from, AskedFrom, allow_nil?: false, public?: true)

    # The key a help page's connection is counted by, never the address. A
    # decision made inside a fix has the fix's run instead.
    attribute(:visitor_key, :string, allow_nil?: true, public?: true)

    # The known fix's id, or `none_fits`.
    attribute(:choice, :string, allow_nil?: false, public?: true)
    attribute(:confidence, :float, allow_nil?: false, public?: true)
    attribute(:model, :string, allow_nil?: false, public?: true)

    attribute(:result, FixResult, allow_nil?: true, public?: true)
    attribute(:reported_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:assist_run, Patchbay.Assist.Run, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes down what Jev chose for one agent, as Patchbay asked it.")

      accept([
        :site,
        :goal,
        :error,
        :asked_from,
        :visitor_key,
        :assist_run_id,
        :choice,
        :confidence,
        :model
      ])
    end

    update :report do
      description("The agent's word on whether the fix worked, taken once.")
      accept([:result])
      validate(present(:result))
      validate(Patchbay.Assist.Validations.NotReported)
      change(set_attribute(:reported_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # The decision's id is what the agent was handed with the answer, so
    # holding it is the whole check. Recording and every read are
    # Patchbay's own and say so by skipping authorization.
    policy action(:report) do
      authorize_if(always())
    end
  end
end
