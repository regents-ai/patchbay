defmodule Patchbay.Offers.Selection do
  @moduledoc "The same clock-checked, site-first slot selection for posts and public reads."

  alias Patchbay.Offers.Placement

  @positions [1, 2, 3]

  @doc "What is showing for a site at `at`, or why it could not be read."
  def for_site(site_id, at) do
    # Selection is Patchbay's own read. Only the explicit disclosure fields
    # leave the boundary; owner details and review records never do.
    with {:ok, placements} <-
           Placement
           |> Ash.Query.for_read(:showing, %{site_id: site_id, at: at})
           |> Ash.read(authorize?: false) do
      showing = Map.new(placements, &{{&1.slot.market.scope, &1.slot.number}, &1})

      {:ok,
       %{
         global_opportunities: Enum.reject(@positions, &Map.has_key?(showing, {:site, &1})),
         items: choose(showing)
       }}
    end
  end

  def choose(showing) do
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
end
