defmodule Patchbay.Repo.Migrations.ThreadsCountReadersAndLikes do
  @moduledoc """
  Threads count their readers, once each, and signed-in readers can like a
  thread's opening post and its replies. Both are new tables; nothing already
  on the board changes.
  """

  use Ecto.Migration

  def up do
    create table(:forum_likes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :report_id,
          references(:forum_reports,
            column: :id,
            name: "forum_likes_report_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :reply_id,
          references(:forum_replies,
            column: :id,
            name: "forum_likes_reply_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      add :author_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "forum_likes_author_profile_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false
    end

    create unique_index(:forum_likes, [:author_profile_id, :report_id, :reply_id],
             name: "forum_likes_one_per_post_index",
             nulls_distinct: false
           )

    create index(:forum_likes, [:report_id])

    create index(:forum_likes, [:reply_id])

    create index(:forum_likes, [:author_profile_id])

    create table(:forum_thread_views, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :viewer, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :report_id,
          references(:forum_reports,
            column: :id,
            name: "forum_thread_views_report_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false
    end

    create unique_index(:forum_thread_views, [:report_id, :viewer],
             name: "forum_thread_views_report_viewer_index"
           )

    create index(:forum_thread_views, [:report_id])
  end

  def down do
    drop_if_exists index(:forum_thread_views, [:report_id])

    drop constraint(:forum_thread_views, "forum_thread_views_report_id_fkey")

    drop_if_exists unique_index(:forum_thread_views, [:report_id, :viewer],
                     name: "forum_thread_views_report_viewer_index"
                   )

    drop table(:forum_thread_views)

    drop_if_exists index(:forum_likes, [:author_profile_id])

    drop_if_exists index(:forum_likes, [:reply_id])

    drop_if_exists index(:forum_likes, [:report_id])

    drop constraint(:forum_likes, "forum_likes_author_profile_id_fkey")

    drop constraint(:forum_likes, "forum_likes_reply_id_fkey")

    drop constraint(:forum_likes, "forum_likes_report_id_fkey")

    drop_if_exists unique_index(:forum_likes, [:author_profile_id, :report_id, :reply_id],
                     name: "forum_likes_one_per_post_index"
                   )

    drop table(:forum_likes)
  end
end
