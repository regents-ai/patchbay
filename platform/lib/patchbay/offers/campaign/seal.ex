defmodule Patchbay.Offers.Campaign.Seal do
  @moduledoc """
  Settles a campaign as it will be kept: its sites as site addresses, only the
  audience it names, who it is shown to sorted and once each, and its id from
  the manifest that results.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Patchbay.Forum.{Origin, TopicTag}
  alias Patchbay.Offers.Campaign

  @address ~r/\A0x[0-9a-f]{40}\z/

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> audience()
    |> tags()
    |> excluded_wallets()
    |> settle([:kinds, :requires])
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

  # Tags as threads carry them: lowercase, hyphens inside.
  defp tags(changeset) do
    tags = Enum.map(Changeset.get_attribute(changeset, :tags) || [], &String.downcase/1)

    if Enum.all?(tags, &TopicTag.valid?/1),
      do: Changeset.force_change_attribute(changeset, :tags, tags |> Enum.uniq() |> Enum.sort()),
      else: Changeset.add_error(changeset, field: :tags, message: "use topic tags")
  end

  defp excluded_wallets(changeset) do
    wallets =
      Enum.map(Changeset.get_attribute(changeset, :excluded_wallets) || [], &String.downcase/1)

    if Enum.all?(wallets, &Regex.match?(@address, &1)),
      do:
        Changeset.force_change_attribute(
          changeset,
          :excluded_wallets,
          wallets |> Enum.uniq() |> Enum.sort()
        ),
      else:
        Changeset.add_error(changeset, field: :excluded_wallets, message: "use wallet addresses")
  end

  defp settle(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      values = Changeset.get_attribute(changeset, field) || []
      Changeset.force_change_attribute(changeset, field, values |> Enum.uniq() |> Enum.sort())
    end)
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
