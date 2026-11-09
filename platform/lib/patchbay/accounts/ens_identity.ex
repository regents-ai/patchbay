defmodule Patchbay.Accounts.EnsIdentity do
  @moduledoc """
  The ENS name and picture Ethereum mainnet publishes for an account's wallet.

  This is a copy of public chain state, not identity evidence: the account's
  own row keeps the verified Privy identity and wallet. Each sign-in asks again
  (`:request_lookup`), and one job, queued in the same transaction, reads the
  account's current wallet and then the chain outside any transaction
  (`LookUp`). A sweep every ten minutes queues a job for a lookup still asked
  for whose job is gone. A wallet with no verified name is stored with none; a
  lookup that keeps failing leaves the last answer standing.

  `wallet_address` is the wallet the row was last read for. Asking again does
  not change it; only a finished lookup does. An account whose wallet has
  since changed is therefore never shown the old wallet's name, while the new
  wallet's lookup runs or after it fails.

  Lookups run only while the server has an Ethereum endpoint
  (`ETHEREUM_READ_RPC_URL`).
  """

  use Ash.Resource,
    domain: Patchbay.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Patchbay.Accounts.EnsIdentity.LookUp

  # Who reads a wallet's verified ENS name: `AgentEns.PrimaryName`; tests use
  # `PatchbayWeb.EnsStandIn`.
  @primary_name Application.compile_env!(:patchbay, [__MODULE__, :primary_name])

  postgres do
    table("account_ens_identities")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:wallet_address, :string, allow_nil?: false)
    attribute(:ens_name, :string, public?: true)
    attribute(:ens_avatar_url, :string, public?: true)

    attribute(:lookup_state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:pending, :done, :failed]]
    )

    timestamps()
  end

  relationships do
    belongs_to :human_account, Patchbay.Accounts.HumanAccount do
      allow_nil?(false)
      attribute_type(:integer)
    end
  end

  identities do
    identity(:unique_human_account, [:human_account_id])
  end

  actions do
    defaults([:read])

    create :request_lookup do
      accept([:human_account_id, :wallet_address])
      change(set_attribute(:lookup_state, :pending))
      change(run_oban_trigger(:look_up))
      upsert?(true)
      upsert_identity(:unique_human_account)
      # The wallet is kept from the first ask and moved only by a finished lookup.
      upsert_fields([:lookup_state, :updated_at])
    end

    update :look_up do
      transaction?(false)
      require_atomic?(false)
      change(LookUp)
    end

    update :lookup_failed do
      change(set_attribute(:lookup_state, :failed))
    end
  end

  oban do
    triggers do
      # Every sign-in queues its own job. The ten-minute sweep picks up a
      # lookup still asked for whose job is gone: one cancelled because a
      # sign-in moved the row on while it ran, or discarded on its last attempt.
      trigger :look_up do
        action(:look_up)
        where(expr(lookup_state == :pending))
        queue(:ens)
        max_attempts(3)
        on_error(:lookup_failed)
        lock_for_update?(false)
        scheduler_cron("*/10 * * * *")
        worker_module_name(Patchbay.Accounts.EnsIdentity.Workers.LookUp)
        scheduler_module_name(Patchbay.Accounts.EnsIdentity.Schedulers.LookUp)
      end
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if(always())
    end

    policy action(:request_lookup) do
      authorize_if(actor_attribute_equals(:role, :system))
    end

    # Chain state anyone can read for themselves, so the account it belongs to
    # is what protects it, not this row.
    policy action(:read) do
      authorize_if(always())
    end
  end

  @doc "Whether the server can read Ethereum mainnet."
  def looking_up?, do: not is_nil(rpc_url())

  @doc "The Ethereum mainnet endpoint lookups read from."
  def rpc_url, do: Application.get_env(:patchbay, :ethereum_read_rpc_url)

  @doc "The module that reads a wallet's verified ENS name and picture."
  def primary_name, do: @primary_name
end
