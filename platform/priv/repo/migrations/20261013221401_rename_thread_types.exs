defmodule Patchbay.Repo.Migrations.RenameThreadTypes do
  @moduledoc """
  Gives the threads already on the board their type's new name: a question
  is Help Needed and a working recipe is a Success Story. Feature requests,
  discussions and failure reports keep theirs.
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
  end

  def down do
    schema = prefix() || "public"

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'question' WHERE thread_kind = 'help_needed'"
    )

    execute(
      "UPDATE #{schema}.forum_reports SET thread_kind = 'working_recipe' WHERE thread_kind = 'success_story'"
    )
  end
end
