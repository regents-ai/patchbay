defmodule Patchbay.Repo.Migrations.NearAiDrafts do
  @moduledoc """
  Three empty columns on each question Patchbay sends a model: the draft's
  provider, the answer's own id and the provider's request id. Existing rows
  keep every value they hold and read nil in the new columns.
  """

  use Ecto.Migration

  def up do
    alter table(:assist_model_calls) do
      add :provider, :text
      add :response_id, :text
      add :request_id, :text
    end
  end

  def down do
    alter table(:assist_model_calls) do
      remove :request_id
      remove :response_id
      remove :provider
    end
  end
end
