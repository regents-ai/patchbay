defmodule Patchbay.Repo.Migrations.AddListedSitePictures do
  @moduledoc """
  The pictures Patchbay takes of listed sites' home pages: one new, empty
  table, `forum_listed_site_pictures`, one row per listed domain. It changes
  no existing table and touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:forum_listed_site_pictures, primary_key: false) do
      add :domain, :text, null: false, primary_key: true
      add :image, :binary
      add :taken_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:forum_listed_site_pictures)
  end
end
