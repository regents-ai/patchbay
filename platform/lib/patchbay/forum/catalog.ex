defmodule Patchbay.Forum.Catalog do
  @moduledoc """
  The researched WebMCP directory. Official support is not a tool catalog.

  Entries come from `priv/data/webmcp_sites.json`. Tools are never invented
  for a supporter banner: only Patchbay's own observed contracts are written
  onto a catalog row, and only when a studio offers them.
  """

  alias Patchbay.Forum

  @spec path() :: Path.t()
  def path, do: Application.app_dir(:patchbay, "priv/data/webmcp_sites.json")

  @spec sync!() :: [Patchbay.Forum.Site.t()]
  def sync! do
    Enum.map(entries(), &upsert!/1)
  end

  @spec entries() :: [map()]
  def entries do
    document = document()
    verified = parse_time(document["last_verified_at"])

    Enum.map(document["entries"], &normalize_entry(&1, verified))
  end

  defp document do
    path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp upsert!(entry) do
    origin = Map.fetch!(entry, :origin)
    Forum.upsert_catalog_entry!(origin, Map.delete(entry, :origin))
  end

  defp normalize_entry(entry, default_verified) do
    verified = parse_time(entry["last_verified_at"]) || default_verified
    captured = parse_time(entry["screenshot_captured_at"]) || default_verified

    %{
      origin: entry["origin"],
      slug: entry["slug"],
      display_name: entry["display_name"],
      entity_type: String.to_existing_atom(entry["entity_type"]),
      organization_name: entry["organization_name"],
      canonical_domain: entry["canonical_domain"],
      support_relationship: String.to_existing_atom(entry["support_relationship"]),
      support_status: String.to_existing_atom(entry["support_status"]),
      support_evidence_url: entry["support_evidence_url"],
      support_evidence_label: entry["support_evidence_label"],
      last_verified_at: verified,
      tool_inventory_status: String.to_existing_atom(entry["tool_inventory_status"]),
      logo_path: entry["logo_path"],
      logo_source_url: entry["logo_source_url"],
      logo_usage_note: entry["logo_usage_note"],
      screenshot_path: entry["screenshot_path"],
      screenshot_source_url: entry["screenshot_source_url"],
      screenshot_captured_at: captured,
      featured_rank: entry["featured_rank"]
    }
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    {:ok, time, _} = DateTime.from_iso8601(value)
    DateTime.truncate(time, :microsecond)
  end
end
