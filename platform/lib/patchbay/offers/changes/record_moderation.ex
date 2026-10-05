defmodule Patchbay.Offers.Changes.RecordModeration do
  @moduledoc """
  Writes the moderator's decision to `Patchbay.Offers.ModerationAction` in
  the same transaction as the change it records, so a decision is never
  made without its audit row or recorded without being made.

  Option `:kind` names the decision, or `:from_argument` takes it from the
  action's `:decision` argument (`:dismissed` or `:confirmed`).
  """

  use Ash.Resource.Change

  alias Patchbay.Offers.ModerationAction
  alias Patchbay.Offers.OfferReport

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      attrs =
        Map.merge(subject(record), %{
          kind: kind(changeset, opts[:kind]),
          reason: Ash.Changeset.get_argument(changeset, :reason),
          idempotency_key: Ash.Changeset.get_argument(changeset, :idempotency_key)
        })

      # The decision's own policy has said who may make it; its audit row
      # follows it in the same transaction, so this skips authorization
      # deliberately.
      ModerationAction
      |> Ash.Changeset.for_create(:record, attrs, actor: context.actor, authorize?: false)
      |> Ash.create()
      |> case do
        {:ok, _action} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp kind(changeset, :from_argument) do
    case Ash.Changeset.get_argument(changeset, :decision) do
      :dismissed -> :dismiss_report
      :confirmed -> :confirm_report
    end
  end

  defp kind(_changeset, kind), do: kind

  defp subject(%OfferReport{} = report),
    do: %{report_id: report.id, placement_id: report.placement_id, version_id: report.version_id}

  defp subject(%Patchbay.Offers.CreativeVersion{} = version), do: %{version_id: version.id}
end
