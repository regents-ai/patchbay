defmodule Patchbay.WalletBench.Note do
  @moduledoc """
  Techtree's words for the bench: what each outcome means, keyed by the
  outcome, and the shared setup (`setup`), how runs combine (`runs`) and when
  the grid started (`grid_started`).
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_notes")
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
    attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:text, :string, allow_nil?: false, public?: true)
  end
end
