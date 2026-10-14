defmodule Patchbay.WalletBench.ExtraNote do
  @moduledoc """
  Something odd Techtree's bench saw about one release of an agent or a
  wallet tool, in Techtree's words, with the run that showed it when there is
  one. `kind` and `id` are the roster's, and `version` is written as a run's
  set records that release (`set_versions`), so a note belongs beside every
  run of that release and of no other. A note explains a result and never
  changes one. Techtree withdraws a note by removing it, so every row here
  stands.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.WalletBench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("wallet_bench_extra_notes")
    schema("techtree_app")
    repo(Patchbay.Repo)
    migrate?(false)
  end

  resource do
    # A release can have several notes, and the view gives them no key.
    require_primary_key?(false)
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
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:id, :string, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:note, :string, allow_nil?: false, public?: true)
    attribute(:run_url, :string, public?: true)
    attribute(:noted_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
