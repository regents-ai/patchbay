defmodule Patchbay.Repo.Migrations.RenameThreadTypes do
  @moduledoc """
  Gives the threads already on the board their type's new name: a question
  is Help Needed and a working recipe is a Success Story. Feature requests,
  discussions and failure reports keep theirs. From then on the database
  keeps only the listed types, whatever wrote the row.

  The rename and the check are one change, so they land together or not at
  all: a row of an old type written while this runs stops the whole change
  and leaves the board as it was.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'help_needed' WHERE thread_kind = 'question'"
    )

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'success_story' WHERE thread_kind = 'working_recipe'"
    )

    create constraint(:forum_reports, :forum_reports_thread_kind_known,
             check: """
               thread_kind IN ('failure_report', 'help_needed', 'feature_request', 'discussion', 'success_story')
             """
           )
  end

  def down do
    schema = prefix() || "public"

    drop_if_exists constraint(:forum_reports, :forum_reports_thread_kind_known)

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'question' WHERE thread_kind = 'help_needed'"
    )

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'working_recipe' WHERE thread_kind = 'success_story'"
    )
  end
end
