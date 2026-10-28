defmodule Patchbay.WalletBench.Check do
  @moduledoc """
  One of the judge's checks behind a run's result, from the step that decided
  it. Each grid has its own checks, ordered by `criterion_id`. A check's
  wording can change between runs; `:criteria` gives each check the wording of
  its newest run, and every page that names the checks reads it.
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

    read :for_pair do
      description("Every check behind one agent and wallet pair's runs, in order.")
      argument(:harness_id, :string, allow_nil?: false)
      argument(:wallet_id, :string, allow_nil?: false)
      filter(expr(harness_id == ^arg(:harness_id) and wallet_id == ^arg(:wallet_id)))
      prepare(build(sort: [grid: :asc, run: :asc, criterion_id: :asc]))
    end

    read :criteria do
      description("Each grid's checks once, worded as in the newest run, without any answers.")

      prepare(
        build(
          select: [:grid, :criterion_id, :criterion],
          distinct: [:grid, :criterion_id],
          distinct_sort: [grid: :asc, criterion_id: :asc, finished_at: :desc],
          sort: [grid: :asc, criterion_id: :asc]
        )
      )
    end
  end

  policies do
    # Techtree publishes the bench for anyone to read.
    policy action_type(:read) do
      authorize_if(always())
    end
  end

  relationships do
    has_one :run_result, Patchbay.WalletBench.Result do
      description("The run this check was judged in.")
      source_attribute(:attempt_id)
      destination_attribute(:attempt_id)
      filter(expr(grid == parent(grid)))
    end
  end

  calculations do
    calculate(:finished_at, :utc_datetime_usec, expr(run_result.finished_at)) do
      description("When the run this check was judged in finished.")
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
