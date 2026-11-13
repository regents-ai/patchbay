defmodule Patchbay.Offers.Campaign.Seal do
  @moduledoc """
  Settles a campaign as it will be kept: its sites as site addresses, only the
  audience it names, and its id from the manifest that results.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Patchbay.Forum.Origin
  alias Patchbay.Offers.Campaign

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> audience()
    |> Changeset.before_action(&seal/1)
  end

  defp audience(changeset) do
    case Changeset.get_attribute(changeset, :audience) do
      :sites -> changeset |> Changeset.force_change_attribute(:group, nil) |> sites()
      :group -> changeset |> Changeset.force_change_attribute(:sites, []) |> group()
      _all -> Changeset.force_change_attributes(changeset, sites: [], group: nil)
    end
  end

  defp sites(changeset) do
    results = Enum.map(Changeset.get_attribute(changeset, :sites) || [], &Origin.normalize/1)

    cond do
      results == [] ->
        Changeset.add_error(changeset, field: :sites, message: "name at least one site")

      Enum.all?(results, &match?({:ok, _site}, &1)) ->
        sites = Enum.sort(for {:ok, site} <- results, uniq: true, do: site)
        Changeset.force_change_attribute(changeset, :sites, sites)

      true ->
        Changeset.add_error(changeset, field: :sites, message: "name each site by its address")
    end
  end

  defp group(changeset) do
    if Changeset.get_attribute(changeset, :group),
      do: changeset,
      else: Changeset.add_error(changeset, field: :group, message: "choose a kind of site")
  end

  defp seal(changeset) do
    fields = Map.new(Campaign.manifest_fields(), &{&1, Changeset.get_attribute(changeset, &1)})

    Changeset.force_change_attribute(
      changeset,
      :campaign_id,
      Patchbay.Offers.hash(Campaign.manifest(fields))
    )
  end
end
