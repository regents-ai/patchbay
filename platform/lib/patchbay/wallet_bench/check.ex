defmodule Patchbay.WalletBench.Check do
  @moduledoc """
  One of the judge's checks behind a run's result, from the step that decided
  it. Each grid has its own checks, ordered by `criterion_id`. A check's
  wording can change between runs; every page that names the checks names
  each by its newest run's wording (`Patchbay.WalletBench.Matrix.criteria/2`).
  """

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
    defaults([:read])
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
