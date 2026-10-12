defmodule Patchbay.Offers.TurnDown do
  @moduledoc """
  Every time an Offer wording was turned down, kept for the admin page.

  A row is written in the same transaction as the turn-down itself: a
  screening that refused the wording, was not sure, or could not run, and an
  admin's block. It keeps its own copy of the words, the Offer's name and
  the reasons, so it still reads the same after the advertiser deletes the
  Offer; the wording it names is then cleared.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table("offer_turn_downs")
    repo(Patchbay.Repo)

    custom_indexes do
      index([:inserted_at])
      index([:version_id])
    end

    references do
      reference(:owner, on_delete: :restrict)
      reference(:version, on_delete: :nilify)
      reference(:market, on_delete: :restrict)
    end
  end

  # A new turn-down tells the open admin page to read again.
  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:log, ["offers:turn_downs"], transform: &__MODULE__.changed_message/1)
  end

  @doc "The PubSub topic a turn-down is announced on."
  @spec topic() :: String.t()
  def topic, do: "offers:turn_downs"

  @doc false
  def changed_message(_notification), do: :offer_turn_downs_changed

  attributes do
    uuid_primary_key(:id)

    # `:safety` or `:relevance` for a screening, `:blocked` for an admin's block.
    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:safety, :relevance, :blocked]]
    )

    attribute(:text, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:label, :string, allow_nil?: false, public?: true)
    attribute(:reason_codes, {:array, :string}, allow_nil?: false, default: [], public?: true)

    # Screening's own words or the admin's reason; admin-only.
    attribute(:private_reason, :string, allow_nil?: true, constraints: [max_length: 2000])

    attribute(:model, :string, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to(:owner, Patchbay.Identity.AgentProfile,
      source_attribute: :owner_profile_id,
      allow_nil?: false,
      public?: true
    )

    belongs_to(:version, Patchbay.Offers.CreativeVersion, allow_nil?: true, public?: true)
    belongs_to(:market, Patchbay.Offers.Market, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :log do
      description("Logs one turn-down, written with the decision it records.")

      accept([
        :kind,
        :text,
        :label,
        :reason_codes,
        :private_reason,
        :model,
        :owner_profile_id,
        :version_id,
        :market_id
      ])
    end
  end

  policies do
    # Written only with the turn-down it records, and read on the admin page
    # only, which checks the admin itself. Both skip authorization
    # deliberately.
    policy action([:log, :read]) do
      forbid_if(always())
    end
  end
end
