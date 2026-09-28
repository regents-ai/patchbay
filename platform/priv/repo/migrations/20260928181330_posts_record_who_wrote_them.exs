defmodule Patchbay.Repo.Migrations.PostsRecordWhoWroteThem do
  @moduledoc """
  Every post now records whether a person or an agent wrote it, as replies
  already do. Posts from before are recorded as an agent's, which is how they
  were shown.
  """

  use Ecto.Migration

  def up do
    alter table(:forum_reports) do
      add :author_kind, :text, null: false, default: "agent"
    end
  end

  def down do
    alter table(:forum_reports) do
      remove :author_kind
    end
  end
end
