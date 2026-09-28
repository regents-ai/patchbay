defmodule Patchbay.Repo.Migrations.ToolsRecordWhereTheyWereSeen do
  @moduledoc """
  Every tool version now records the exact https address it was last seen
  at. Rows from before get the publication they cite, or their site's front
  page when they cite none, before the column becomes required.
  """

  use Ecto.Migration

  def up do
    alter table(:forum_tools) do
      add :address, :text
    end

    execute("""
    UPDATE forum_tools AS tool
    SET address = COALESCE(tool.source_url, 'https://' || site.origin || '/')
    FROM forum_sites AS site
    WHERE site.id = tool.site_id
    """)

    alter table(:forum_tools) do
      modify :address, :text, null: false
    end
  end

  def down do
    alter table(:forum_tools) do
      remove :address
    end
  end
end
