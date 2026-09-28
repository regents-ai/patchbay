defmodule Patchbay.Repo.Migrations.PostsCarryPictures do
  @moduledoc """
  A forum post can carry up to three pictures its author added, kept in
  their own table so a post is read without them.
  """

  use Ecto.Migration

  def up do
    create table(:forum_post_pictures, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :format, :text, null: false
      add :image, :binary, null: false
      add :position, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :report_id,
          references(:forum_reports,
            column: :id,
            name: "forum_post_pictures_report_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:forum_post_pictures, [:report_id, :position],
             name: "forum_post_pictures_one_per_place_index"
           )
  end

  def down do
    drop table(:forum_post_pictures)
  end
end
