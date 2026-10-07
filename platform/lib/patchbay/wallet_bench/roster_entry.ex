defmodule Patchbay.WalletBench.RosterEntry do
  @moduledoc "An agent or a wallet on the bench, with the version last seen."

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_roster")
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
    attribute(:kind, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:version, :string, public?: true)
  end
end
