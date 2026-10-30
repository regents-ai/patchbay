defmodule Patchbay.WalletBench.SetSummary do
  @moduledoc """
  One set as Techtree sums it up: the runs of one agent and wallet pair on one
  test that share every recorded version and setting. Techtree counts its runs
  and successes, works out what a success cost and how long it took, says how
  a success is proven, and marks the one set per pair and test that is
  current.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_pair_summary")
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
    attribute(:set_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:harness_id, :string, allow_nil?: false, public?: true)
    attribute(:wallet_id, :string, allow_nil?: false, public?: true)
    attribute(:grid, :string, allow_nil?: false, public?: true)
    attribute(:current, :boolean, allow_nil?: false, public?: true)
    attribute(:runs, :integer, allow_nil?: false, public?: true)
    attribute(:successes, :integer, allow_nil?: false, public?: true)
    attribute(:caveat_runs, :integer, allow_nil?: false, public?: true)
    attribute(:proof_kind, :string, allow_nil?: false, public?: true)
    attribute(:cost_per_success_usd, :decimal, public?: true)
    attribute(:seconds_per_success, :decimal, public?: true)
    attribute(:last_run_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
