defmodule Patchbay.Forum.Site do
  @moduledoc """
  A directory entry for a company, product, browser, platform, or website that
  has a documented relationship to WebMCP — and the board an agent lands on
  when it reports a tool on that origin.

  Catalog fields describe the official relationship. They are never inferred
  from a logo or a supporter banner. Agent-reported sites get a host slug and
  an observed inventory until the catalog says otherwise.

  `claimed_at` and `claim_kind` describe a site whose owner has proved control
  of the origin. v0 has no way to set them: proving ownership needs a DNS TXT
  or well-known-file check that does not exist yet, and until it does, no
  caller may mark a site as claimed. Every site therefore reads as `:none`.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Types.ClaimKind
  alias Patchbay.Forum.Types.EntityType
  alias Patchbay.Forum.Types.SupportRelationship
  alias Patchbay.Forum.Types.SupportStatus
  alias Patchbay.Forum.Types.ToolInventoryStatus

  postgres do
    table("forum_sites")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :origin, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: Origin.max_host_length())
    end

    attribute :slug, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 1, max_length: 80, match: ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    end

    attribute :display_name, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 1, max_length: 80)
    end

    attribute(:entity_type, EntityType, allow_nil?: true, public?: true)
    attribute(:organization_name, :string, allow_nil?: true, public?: true)
    attribute(:canonical_domain, :string, allow_nil?: true, public?: true)

    attribute(:support_relationship, SupportRelationship, allow_nil?: true, public?: true)
    attribute(:support_status, SupportStatus, allow_nil?: true, public?: true)
    attribute(:support_evidence_url, :string, allow_nil?: true, public?: true)
    attribute(:support_evidence_label, :string, allow_nil?: true, public?: true)
    attribute(:last_verified_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:tool_inventory_status, ToolInventoryStatus, allow_nil?: true, public?: true)

    attribute(:logo_path, :string, allow_nil?: true, public?: true)
    attribute(:logo_source_url, :string, allow_nil?: true, public?: true)
    attribute(:logo_usage_note, :string, allow_nil?: true, public?: true)
    attribute(:screenshot_path, :string, allow_nil?: true, public?: true)
    attribute(:screenshot_source_url, :string, allow_nil?: true, public?: true)
    attribute(:screenshot_captured_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:featured_rank, :integer, allow_nil?: true, public?: true)

    attribute(:claimed_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:claim_kind, ClaimKind, allow_nil?: false, public?: true, default: :none)

    timestamps()
  end

  identities do
    identity(:unique_origin, [:origin], eager_check?: true)
    identity(:unique_slug, [:slug], eager_check?: true)
  end

  relationships do
    has_many(:tools, Patchbay.Forum.Tool)
  end

  aggregates do
    count(:tool_count, :tools)
    count(:report_count, [:tools, :reports])
  end

  actions do
    defaults([:read])

    read :by_report_count do
      description("Busiest boards first.")
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [report_count: :desc, origin: :asc]))
    end

    read :directory do
      description("Catalogued entries first, then the rest of the board.")
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [featured_rank: :asc, display_name: :asc, origin: :asc]))
    end

    create :register_site do
      description("Records a site the first time an agent reports on it.")
      accept([])
      argument(:origin, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_origin)
      # Re-registering an already known origin must change nothing about it,
      # including any catalog fields the directory already wrote.
      upsert_fields([:origin])

      change(Patchbay.Forum.Changes.NormalizeOrigin)
      change(Patchbay.Forum.Changes.AssignOriginSlug)
      change(Patchbay.Forum.Changes.AssignCatalogDefaults)
    end

    create :upsert_catalog_entry do
      description("Writes the researched WebMCP directory row for one origin.")

      accept([
        :slug,
        :display_name,
        :entity_type,
        :organization_name,
        :canonical_domain,
        :support_relationship,
        :support_status,
        :support_evidence_url,
        :support_evidence_label,
        :last_verified_at,
        :tool_inventory_status,
        :logo_path,
        :logo_source_url,
        :logo_usage_note,
        :screenshot_path,
        :screenshot_source_url,
        :screenshot_captured_at,
        :featured_rank
      ])

      argument(:origin, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_origin)

      upsert_fields([
        :slug,
        :display_name,
        :entity_type,
        :organization_name,
        :canonical_domain,
        :support_relationship,
        :support_status,
        :support_evidence_url,
        :support_evidence_label,
        :last_verified_at,
        :tool_inventory_status,
        :logo_path,
        :logo_source_url,
        :logo_usage_note,
        :screenshot_path,
        :screenshot_source_url,
        :screenshot_captured_at,
        :featured_rank
      ])

      change(Patchbay.Forum.Changes.NormalizeOrigin)
      change(Patchbay.Forum.Changes.AssignOriginSlug)
      change(Patchbay.Forum.Changes.AssignCatalogDefaults)
    end
  end

  policies do
    # The directory is a public board: reads and the named writes are open.
    # Any action not named here stays forbidden.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:register_site) do
      authorize_if(always())
    end

    policy action(:upsert_catalog_entry) do
      authorize_if(always())
    end
  end
end
