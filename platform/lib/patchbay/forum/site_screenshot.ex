defmodule Patchbay.Forum.SiteScreenshot do
  @moduledoc """
  The picture Patchbay took of a site's page for its card, kept apart from
  the site so the image is read only when it is served. One per site.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_site_screenshots")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:image, :binary, allow_nil?: false, public?: true)
    attribute(:captured_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)
  end

  identities do
    identity(:one_per_site, [:site_id])
  end

  actions do
    defaults([:read])

    create :store do
      description("Keeps the picture of a site's page, replacing an earlier one.")
      accept([:site_id, :image, :captured_at])
      upsert?(true)
      upsert_identity(:one_per_site)
      upsert_fields([:image, :captured_at])
    end
  end

  policies do
    # The picture is shown on a public card. Storing one is Patchbay's own
    # work and is never reached from outside.
    policy action_type(:read) do
      authorize_if(always())
    end
  end
end
