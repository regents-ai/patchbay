defmodule Patchbay.WalletBench.Result do
  @moduledoc """
  One run of one agent and wallet pair in one grid (install, or make a
  wallet), as Techtree ruled it. Runs are numbered in the order they finished.
  A run's steps are listed in order, and `decided_by` names the step whose
  ruling is the run's result: a safety failure in any step, otherwise the last.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_results")
    schema("techtree_app")
    repo(Patchbay.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])

    read :for_pair do
      description("Every run of one agent and wallet pair, in order.")
      argument(:harness_id, :string, allow_nil?: false)
      argument(:wallet_id, :string, allow_nil?: false)
      filter(expr(harness_id == ^arg(:harness_id) and wallet_id == ^arg(:wallet_id)))
      prepare(build(sort: [grid: :asc, run: :asc]))
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
    attribute(:harness_id, :string, allow_nil?: false, public?: true)
    attribute(:wallet_id, :string, allow_nil?: false, public?: true)
    attribute(:run, :integer, allow_nil?: false, public?: true)
    attribute(:outcome, :string, public?: true)
    attribute(:outcome_detail, :string, public?: true)
    attribute(:plain_file, :string, public?: true)
    attribute(:decided_by, :string, allow_nil?: false, public?: true)
    attribute(:turns, {:array, Patchbay.WalletBench.Turn}, allow_nil?: false, public?: true)
    attribute(:run_url, :string, allow_nil?: false, public?: true)
    attribute(:versions, :map, public?: true)
    attribute(:finished_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
