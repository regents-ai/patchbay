defmodule Patchbay.NearFunding.Funding do
  @moduledoc """
  One Fund with NEAR request (`Patchbay.NearFunding`): who asked (the paired
  agent and its person), the USDC it delivers in base units, the agent's own
  wallet it goes to, the NEAR account any refund goes back to, the quote as
  the service returned it, the deposit address, where the swap stands and its
  two transactions once known.

  Starting one asks the service for a live quote before the row is written,
  outside any transaction (`Patchbay.NearFunding.Changes.Quote`). While it is
  waiting or under way, a job reads its progress once a minute (`:refresh`,
  the AshOban trigger of the same name) and stops at Arrived, Refunded or
  Failed, or an hour after a deposit address that never received NEAR
  closed. Each change is told to the open page on `"near_funding:<id>"`.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.NearFunding,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban]

  import Ash.Expr

  # A NEAR account id: named (`alice.near`) or implicit (64 hex characters).
  @near_account ~r/\A(?=.{2,64}\z)(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+\z/

  postgres do
    table("near_fundings")
    repo(Patchbay.Repo)
  end

  oban do
    triggers do
      trigger :refresh do
        action(:refresh)
        queue(:outside_calls)

        where(
          expr(
            state == :processing or (state == :pending_deposit and deadline > ago(1, :hour))
          )
        )

        max_attempts(3)
        lock_for_update?(false)
        scheduler_cron("* * * * *")
        worker_module_name(Patchbay.NearFunding.Funding.Workers.Refresh)
        scheduler_module_name(Patchbay.NearFunding.Funding.Schedulers.Refresh)
      end
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:record_status, ["near_funding", :id])
  end

  attributes do
    uuid_primary_key(:id)

    # The paired agent (`RegentAgents.PairedAgent`) and its person.
    attribute(:pairing_id, :uuid, allow_nil?: false, public?: true)
    attribute(:privy_user_id, :string, allow_nil?: false, sensitive?: true)

    attribute :usdc_amount, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 1_000_000_000)
    end

    attribute(:recipient, :string, allow_nil?: false, public?: true)
    attribute(:refund_to, :string, allow_nil?: false, public?: true)

    attribute(:quote, :map, allow_nil?: false, public?: true)
    attribute(:near_amount, :string, allow_nil?: false, public?: true)
    attribute(:time_estimate_s, :integer, allow_nil?: false, public?: true)
    attribute(:deadline, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:deposit_address, :string, allow_nil?: false, public?: true)

    attribute :state, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending_deposit)
      constraints(one_of: [:pending_deposit, :processing, :success, :refunded, :failed])
    end

    attribute(:origin_tx, :string, allow_nil?: true, public?: true)
    attribute(:destination_tx, :string, allow_nil?: true, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_deposit_address, [:deposit_address])
  end

  actions do
    defaults([:read])

    read :latest do
      description("A person's newest funding.")
      argument(:privy_user_id, :string, allow_nil?: false)
      filter(expr(privy_user_id == ^arg(:privy_user_id)))
      prepare(build(sort: [inserted_at: :desc], limit: 1))
    end

    create :start do
      description("A live quote for the USDC asked for, and the address to send NEAR to.")
      accept([:pairing_id, :privy_user_id, :recipient, :refund_to, :usdc_amount])

      validate(match(:recipient, ~r/\A0x[0-9a-fA-F]{40}\z/))

      validate(match(:refund_to, @near_account),
        message: "must be a NEAR account, such as alice.near"
      )

      change(Patchbay.NearFunding.Changes.Quote)
    end

    update :refresh do
      description("Reads where the swap stands. It calls the service, so it holds no transaction.")
      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.NearFunding.Refresh)
    end

    update :record_status do
      description("Keeps where the swap stands and its transactions.")
      accept([:state, :origin_tx, :destination_tx])
    end
  end

  @doc "Whether a funding has reached Arrived, Refunded or Failed."
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{state: state}), do: state in [:success, :refunded, :failed]

  @type t :: %__MODULE__{}
end
