defmodule Patchbay.WalletBench.Fixed do
  @moduledoc """
  Squares that never run, with the outcome they keep. `"*"` in a key means
  every agent, every wallet or both grids.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_fixed")
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
    attribute(:harness_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:wallet_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:grid, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:fixed_outcome, :string, allow_nil?: false, public?: true)
    attribute(:fixed_reason, :string, allow_nil?: false, public?: true)
  end
end
