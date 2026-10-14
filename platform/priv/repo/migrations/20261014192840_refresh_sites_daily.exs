defmodule Patchbay.Repo.Migrations.RefreshSitesDaily do
  @moduledoc """
  Every site is refreshed once a day and photographed once a week
  (`Patchbay.Forum.Site`'s `:refresh` and `:take_picture`). Each site keeps
  when it was last refreshed, and when its last picture could not be taken.

  The directory's pictures that came with the code are dropped, so Patchbay
  takes its own of every site within the hour; every site gets the page its
  picture is taken of, its front page unless the directory names another.
  Going back removes the two columns but does not bring the old pictures back.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    alter table(:forum_sites) do
      add :picture_failed_at, :utc_datetime_usec
      add :refreshed_at, :utc_datetime_usec
    end

    execute("""
    UPDATE #{schema}.forum_sites
    SET screenshot_path = NULL, screenshot_captured_at = NULL
    WHERE screenshot_path LIKE '/images/directory/%'
    """)

    execute("""
    UPDATE #{schema}.forum_sites
    SET screenshot_source_url = 'https://' || origin || '/'
    WHERE screenshot_source_url IS NULL
    """)
  end

  def down do
    alter table(:forum_sites) do
      remove :refreshed_at
      remove :picture_failed_at
    end
  end
end
