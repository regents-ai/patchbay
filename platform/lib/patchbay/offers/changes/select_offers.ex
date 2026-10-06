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
  alias Patchbay.Offers.Placement

  @positions [1, 2, 3]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      at = DateTime.utc_now()
      site_id = Ash.Changeset.get_attribute(changeset, :site_id)
      showing = showing(site_id, at)

      changeset
      |> Ash.Changeset.force_change_attribute(:selected_at, at)
      |> Ash.Changeset.force_change_attribute(
        :global_opportunities,
        Enum.reject(@positions, &Map.has_key?(showing, {:site, &1}))
      )
      |> Ash.Changeset.put_context(:offers_chosen, choose(showing))
      |> Ash.Changeset.after_action(&record_items/2)
    end)
  end

  defp showing(site_id, at) do
    # Patchbay chooses what to show itself, so this read skips authorization
    # deliberately; placements are public in any case.
    Placement
    |> Ash.Query.for_read(:showing, %{site_id: site_id, at: at})
    |> Ash.read!(authorize?: false)
    |> Map.new(&{{&1.slot.market.scope, &1.slot.number}, &1})
  end

  defp choose(showing) do
    for position <- @positions,
        {scope, placement} <- [pick(showing, position)],
        placement != nil,
        do: {position, scope, placement}
  end

  defp pick(showing, position) do
    case Map.fetch(showing, {:site, position}) do
      {:ok, placement} -> {:site, placement}
      :error -> {:global, Map.get(showing, {:global, position})}
    end
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
