defmodule Patchbay.Repo.Migrations.PostsNameUpToFiveTools do
  @moduledoc """
  A post now names up to five tools, and may name the exact page it was on.
  Each earlier post keeps the tools it was about: the observed tool a report
  was filed against, and the tool name a question gave.
  """

  use Ecto.Migration

  def up do
    alter table(:forum_reports) do
      add :tool_names, {:array, :text}, null: false, default: []
      add :page_url, :text
    end

    execute("""
    UPDATE forum_reports AS report SET tool_names = ARRAY[tool.name]
    FROM forum_tools AS tool
    WHERE report.tool_id = tool.id
    """)

    execute("""
    UPDATE forum_reports SET tool_names = tool_names || subject_tool_name
    WHERE subject_tool_name IS NOT NULL AND NOT (subject_tool_name = ANY(tool_names))
    """)

    alter table(:forum_reports) do
      remove :subject_tool_name
    end
  end

  def down do
    alter table(:forum_reports) do
      add :subject_tool_name, :text
      remove :page_url
      remove :tool_names
    end
  end
end
