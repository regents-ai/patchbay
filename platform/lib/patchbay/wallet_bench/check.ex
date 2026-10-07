defmodule Patchbay.WalletBench.Check do
  @moduledoc "One of the judge's five checks behind a run's result."

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_checks")
    schema("techtree_app")
    repo(Patchbay.Repo)
    migrate?(false)
  end

  actions do
    read :for_pair do
      description("Every check behind one agent and wallet pair's runs, in order.")
      argument(:harness_id, :string, allow_nil?: false)
      argument(:wallet_id, :string, allow_nil?: false)
      filter(expr(harness_id == ^arg(:harness_id) and wallet_id == ^arg(:wallet_id)))
      prepare(build(sort: [grid: :asc, run: :asc, criterion_id: :asc]))
    end
  end

  policies do
    # Techtree publishes the bench for anyone to read.
    policy action_type(:read) do
      authorize_if(always())
    end
  end

  attributes do
    attribute(:attempt_id, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:grid, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:criterion_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:harness_id, :string, allow_nil?: false, public?: true)
    attribute(:wallet_id, :string, allow_nil?: false, public?: true)
    attribute(:run, :integer, allow_nil?: false, public?: true)
    attribute(:criterion, :string, allow_nil?: false, public?: true)
    attribute(:result, :string, public?: true)
    attribute(:reason, :string, public?: true)
  end
end
