defmodule Patchbay.Offers.DailySave do
  @moduledoc """
  How many Offer wordings one account has saved on one UTC day, new Offers
  and edits alike. Counted here rather than from the saved wordings, so
  deleting an Offer never gives a day's saves back.

  Written only by `Patchbay.Offers.Changes.DailyOfferLimit`, under the
  account's lock, in the same transaction as the save it counts.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("offer_daily_saves")
    repo(Patchbay.Repo)

    references do
      reference(:owner, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:day, :date, allow_nil?: false, public?: true)
    attribute(:saves, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
  end

  identities do
    identity(:unique_day, [:owner_profile_id, :day])
  end

  relationships do
    belongs_to(:owner, Patchbay.Identity.AgentProfile,
      source_attribute: :owner_profile_id,
      allow_nil?: false,
      public?: true
    )
  end

  actions do
    defaults([:read])

    create :count do
      description("Keeps the day's count of saves for one account.")
      accept([:owner_profile_id, :day, :saves])
      upsert?(true)
      upsert_identity(:unique_day)
      upsert_fields([:saves])
    end
  end

  policies do
    # Read and written only inside a save, under the account's lock, whose
    # own policy has said who may save.
    policy action([:count, :read]) do
      forbid_if(always())
    end
  end
end
