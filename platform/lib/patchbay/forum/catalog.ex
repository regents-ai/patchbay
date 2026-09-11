defmodule Patchbay.Forum.Catalog do
  @moduledoc """
  The researched WebMCP directory. Official support is not a tool catalog.

  Entries come from `priv/data/webmcp_sites.json`. Tools are never invented
  for a supporter banner. The one inventory this server publishes on its own
  authority is Patchbay's: the tool manifest it serves at
  `/forum/capabilities`, written onto this deployment's own site row as
  official tools.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.{Capabilities, RoomMirror}
  alias Patchbay.Forum.Types.{EntityType, SupportRelationship, SupportStatus, ToolInventoryStatus}
  alias Patchbay.Patchbay.{CanonicalJSON, Digest}

  @spec path() :: Path.t()
  def path, do: Application.app_dir(:patchbay, "priv/data/webmcp_sites.json")

  @doc "Writes every catalog entry, its published tools, and Patchbay's own inventory. Runs at boot."
  @spec sync!() :: [Patchbay.Forum.Site.t()]
  def sync! do
    sites =
      for entry <- entries() do
        site = upsert!(entry)
        Enum.each(entry.tools, &publish_entry_tool!(site, entry, &1))
        site
      end

    _ = publish_own_tools!()
    sites
  end

  @doc "Writes the catalog entries only; cheap enough to run before a directory read."
  @spec sync_entries!() :: [Patchbay.Forum.Site.t()]
  def sync_entries! do
    Enum.map(entries(), &upsert!/1)
  end

  # A catalog entry may carry the tool list its owner publishes. Each row
  # cites that publication as its source; nothing is inferred from support.
  defp publish_entry_tool!(site, entry, tool) do
    definition = %{
      name: tool["name"],
      description: tool["description"],
      source_url: entry.support_evidence_url
    }

    Forum.publish_catalog_tool!(%{
      site_id: site.id,
      name: definition.name,
      contract_sha256: definition |> CanonicalJSON.encode() |> Digest.sha256(),
      description: definition.description,
      stable_key: definition.name,
      published_name: definition.name,
      display_name: definition.name,
      raw_definition: definition,
      source_kind: :official,
      source_url: definition.source_url,
      status: :active
    })
  end

  @doc """
  Publishes this deployment's forum tools as the official inventory of its
  own site. The digest is the manifest entry's canonical JSON, so a changed
  summary or auth level is a new contract version.
  """
  @spec publish_own_tools!() :: [Patchbay.Forum.Tool.t()]
  def publish_own_tools! do
    origin = RoomMirror.origin()
    site = Forum.register_site!(origin)
    source_url = "https://" <> origin <> "/forum/capabilities"

    Enum.map(Capabilities.tools(), fn %{name: name} = tool ->
      Forum.publish_catalog_tool!(%{
        site_id: site.id,
        name: name,
        contract_sha256: tool |> CanonicalJSON.encode() |> Digest.sha256(),
        description: tool.summary,
        stable_key: name,
        published_name: name,
        display_name: name,
        protocol_version: tool.schema_version,
        raw_definition: tool,
        source_kind: :official,
        source_url: source_url,
        status: :active
      })
    end)
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
    Forum.upsert_catalog_entry!(origin, Map.drop(entry, [:origin, :tools]))
  end

  defp normalize_entry(entry, default_verified) do
    verified = parse_time(entry["last_verified_at"]) || default_verified
    captured = parse_time(entry["screenshot_captured_at"]) || default_verified

    %{
      origin: entry["origin"],
      slug: entry["slug"],
      display_name: entry["display_name"],
      entity_type: enum!(EntityType, entry["entity_type"]),
      organization_name: entry["organization_name"],
      canonical_domain: entry["canonical_domain"],
      support_relationship: enum!(SupportRelationship, entry["support_relationship"]),
      support_status: enum!(SupportStatus, entry["support_status"]),
      support_evidence_url: entry["support_evidence_url"],
      support_evidence_label: entry["support_evidence_label"],
      last_verified_at: verified,
      tool_inventory_status: enum!(ToolInventoryStatus, entry["tool_inventory_status"]),
      logo_path: entry["logo_path"],
      logo_source_url: entry["logo_source_url"],
      logo_usage_note: entry["logo_usage_note"],
      screenshot_path: entry["screenshot_path"],
      screenshot_source_url: entry["screenshot_source_url"],
      screenshot_captured_at: captured,
      featured_rank: entry["featured_rank"],
      tools: entry["tools"] || []
    }
  end

  # Let the owning enum load and validate its values. The VM's atom table is
  # not a catalog schema, especially before resources load on a fresh boot.
  defp enum!(type, value) do
    {:ok, value} = type.match(value)
    value
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    {:ok, time, _} = DateTime.from_iso8601(value)
    DateTime.truncate(time, :microsecond)
  end
end
