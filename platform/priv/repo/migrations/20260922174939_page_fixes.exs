defmodule Patchbay.Repo.Migrations.PageFixes do
  @moduledoc """
  Free fixes from the page: a run may open without a payment or a payer,
  under a grant counted by a connection key, and one browser has one open
  run at a time. Generated with `mix ash.codegen`.
  """

  use Ecto.Migration

  def up do
    alter table(:assist_runs) do
      add :grant, :text, null: false, default: "paid"
      add :visitor_key, :text
      modify :payer_profile_id, :uuid, null: true
      modify :payment_intent_id, :uuid, null: true
    end

    create unique_index(:assist_runs, [:browser_session_id],
             name: "assist_runs_one_open_run_per_browser_index",
             where: "(status IN ('paid', 'running'))"
           )
  end

  def down do
    drop_if_exists unique_index(:assist_runs, [:browser_session_id],
                     name: "assist_runs_one_open_run_per_browser_index"
                   )

    alter table(:assist_runs) do
      modify :payment_intent_id, :uuid, null: false
      modify :payer_profile_id, :uuid, null: false
      remove :visitor_key
      remove :grant
    end
  end
end
