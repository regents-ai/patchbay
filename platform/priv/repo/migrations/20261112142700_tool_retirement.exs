defmodule Patchbay.Repo.Migrations.ToolRetirement do
  @moduledoc """
  What a site's check did, kept as facts of their own: four empty columns.

  On a site's check, the front page it read (`page_url`) and when it read
  that page whole (`page_read_at`). On a tool, when a check last found it on
  the page it read (`check_found_at`) and when a check retired it
  (`retired_at`). The check's own job fills them from its next run on.

  Adds the columns only; it touches no row. Every existing check and tool
  keeps all four empty.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:site_checks) do
      add :page_url, :text
      add :page_read_at, :utc_datetime_usec
    end

    alter table(:forum_tools) do
      add :check_found_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:forum_tools) do
      remove :retired_at
      remove :check_found_at
    end

    alter table(:site_checks) do
      remove :page_read_at
      remove :page_url
    end
  end
end
