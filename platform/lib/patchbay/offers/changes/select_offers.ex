defmodule Patchbay.Offers.Changes.SelectOffers do
  @moduledoc """
  Fills each of positions 1, 2 and 3 on its own: the site's slot of that
  number if its placement is showing, otherwise Global's slot of the same
  number if that one is showing, otherwise nothing. Positions are never
  reordered and an empty position is never filled from another number.

  What is showing is read once, at the delivery's own time, so expiry is
  taken from the clock rather than from a job that may be late.
  """

  use Ash.Resource.Change

  alias Patchbay.Offers.DeliveryItem
  alias Patchbay.Offers.Selection

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      at = DateTime.utc_now()
      site_id = Ash.Changeset.get_attribute(changeset, :site_id)
      selection = Selection.for_site(site_id, at)

      changeset
      |> Ash.Changeset.force_change_attribute(:selected_at, at)
      |> Ash.Changeset.force_change_attribute(
        :global_opportunities,
        selection.global_opportunities
      )
      |> Ash.Changeset.put_context(:offers_chosen, selection.items)
      |> Ash.Changeset.after_action(&record_items/2)
    end)
  end

  defp record_items(changeset, delivery) do
    chosen = changeset.context.offers_chosen

    items =
      chosen
      |> Enum.map(fn {position, scope, placement} ->
        %{
          delivery_id: delivery.id,
          position: position,
          scope: scope,
          placement_id: placement.id,
          version_id: placement.version_id
        }
      end)
      # Items are written only with their delivery, here, so this skips
      # authorization deliberately.
      |> Ash.bulk_create!(DeliveryItem, :record,
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )
      |> Map.fetch!(:records)
      |> Enum.sort_by(& &1.position)
      |> Enum.zip(chosen)
      |> Enum.map(fn {item, {_position, _scope, placement}} ->
        %{item | placement: placement, version: placement.version}
      end)

    {:ok, %{delivery | items: items}}
  end
end
