defmodule Patchbay.Repo.Migrations.OfferRequestKeys do
  @moduledoc """
  Every saved Offer and every wording now carries the request key its form
  or agent made for it, so a repeated save answers with the first one
  instead of saving again.

  Offers and wordings saved before have no key. Each is given its own id,
  written as text, which is unique to it, so no earlier save is changed or
  merged and none can be mistaken for another. Then the key is required.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    alter table(:offer_creatives) do
      add :request_key, :text
    end

    execute("UPDATE #{schema}.offer_creatives SET request_key = id::text")

    alter table(:offer_creatives) do
      modify :request_key, :text, null: false
    end

    create unique_index(:offer_creatives, [:owner_profile_id, :request_key],
             name: "offer_creatives_unique_request_index"
           )

    alter table(:offer_creative_versions) do
      add :request_key, :text
    end

    execute("UPDATE #{schema}.offer_creative_versions SET request_key = id::text")

    alter table(:offer_creative_versions) do
      modify :request_key, :text, null: false
    end

    create unique_index(:offer_creative_versions, [:creative_id, :request_key],
             name: "offer_creative_versions_unique_request_index"
           )
  end

  def down do
    drop_if_exists unique_index(:offer_creative_versions, [:creative_id, :request_key],
                     name: "offer_creative_versions_unique_request_index"
                   )

    alter table(:offer_creative_versions) do
      remove :request_key
    end

    drop_if_exists unique_index(:offer_creatives, [:owner_profile_id, :request_key],
                     name: "offer_creatives_unique_request_index"
                   )

    alter table(:offer_creatives) do
      remove :request_key
    end
  end
end
