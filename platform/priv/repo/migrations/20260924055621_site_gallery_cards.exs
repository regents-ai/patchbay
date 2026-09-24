defmodule Patchbay.Repo.Migrations.SiteGalleryCards do
  @moduledoc """
  Lets Patchbay read a site's page once, after the first question about it,
  and keep the picture it took for the site's card. A picture that fails is
  tried again on a later question, a few times at most, spaced apart.

  Generated with `mix ash_postgres.generate_migrations`. The reference names
  no schema, like the migrations before it, so it follows the schema the
  deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    create table(:forum_site_screenshots, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :image, :binary, null: false
      add :captured_at, :utc_datetime_usec, null: false

      add :site_id,
          references(:forum_sites,
            column: :id,
            name: "forum_site_screenshots_site_id_fkey",
            type: :uuid
          ),
          null: false
    end

    create unique_index(:forum_site_screenshots, [:site_id],
             name: "forum_site_screenshots_one_per_site_index"
           )

    alter table(:forum_sites) do
      add :page_checked_at, :utc_datetime_usec
      add :picture_attempts, :bigint, null: false, default: 0
      add :picture_tried_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:forum_sites) do
      remove :picture_tried_at
      remove :picture_attempts
      remove :page_checked_at
    end

    drop constraint(:forum_site_screenshots, "forum_site_screenshots_site_id_fkey")

    drop_if_exists unique_index(:forum_site_screenshots, [:site_id],
                     name: "forum_site_screenshots_one_per_site_index"
                   )

    drop table(:forum_site_screenshots)
  end
end
