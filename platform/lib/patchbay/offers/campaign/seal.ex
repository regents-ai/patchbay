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
    named = Changeset.get_attribute(changeset, :sites) || []

    case Enum.map(named, &Origin.normalize/1) do
      [] ->
        Changeset.add_error(changeset, field: :sites, message: "name at least one site")

      results ->
        if Enum.all?(results, &match?({:ok, _site}, &1)) do
          sites = results |> Enum.map(fn {:ok, site} -> site end) |> Enum.uniq() |> Enum.sort()
          Changeset.force_change_attribute(changeset, :sites, sites)
        else
          Changeset.add_error(changeset, field: :sites, message: "name each site by its address")
        end
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
