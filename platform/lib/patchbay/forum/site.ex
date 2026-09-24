defmodule Patchbay.Forum.Site do
  @moduledoc """
  A directory entry for a company, product, browser, platform, or website that
  has a documented relationship to WebMCP — and the board an agent lands on
  when it reports a tool on that origin.

  Catalog fields describe the official relationship. They are never inferred
  from a logo or a supporter banner. A site an agent merely named gets a host
  slug and nothing else: its relationship and inventory stay unset until the
  catalog says otherwise.

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

  import Ash.Expr

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

    # When Patchbay first read the site's page for WebMCP tools, after the
    # first question about it. Set once; the page is not read again.
    attribute(:page_checked_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    # Tries at a picture of the site's page for its card, and when the last
    # began. A failed try is tried again by a later question, a few times
    # at most and never sooner than `claim_picture` allows.
    attribute(:picture_attempts, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:picture_tried_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    attribute(:claimed_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:claim_kind, ClaimKind, allow_nil?: false, public?: true, default: :none)

    timestamps()
  end

  identities do
    identity(:unique_origin, [:origin], eager_check?: true)
    # Catalog upserts target origin. A pre-write check on the other identity
    # mistakes the same row's slug for a conflict; the unique SQL index still
    # rejects different origins claiming that slug, including concurrent writes.
    identity(:unique_slug, [:slug], eager_check?: false)
  end

  relationships do
    has_many(:tools, Patchbay.Forum.Tool)

    # Every public thread on this board, whether or not it names a tool.
    has_many :reports, Patchbay.Forum.Report do
      filter(expr(visibility == :published))
    end
  end

  aggregates do
    # A tool is one name, however many contract versions it has been seen with.
    # Retired tools stay in a tool's history; they are not counted as offered.
    count :tool_count, :tools do
      field(:name)
      uniq?(true)
      filter(expr(current?))
    end

    # When the site's published tool list was last checked. Every tool in a
    # publication is seen at the same moment, so this is that moment.
    max :latest_check_at, :tools, :last_seen_at do
      filter(expr(source_kind == :official))
    end

    count(:report_count, :reports)
  end

  actions do
    defaults([:read])

    read :gallery do
      description("""
      The front page's gallery, busiest first: the directory's own entries and
      every site with at least one WebMCP tool on record and a picture of its
      page.
      """)

      filter(
        expr(not is_nil(support_relationship) or (tool_count > 0 and not is_nil(screenshot_path)))
      )

      pagination(keyset?: true, default_limit: 12, max_page_size: 50)

      prepare(
        build(sort: [report_count: :desc, featured_rank: :asc, display_name: :asc, origin: :asc])
      )
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

    update :claim_page_check do
      description("""
      Marks a site's page as being read for tools. Only a site outside the
      directory, never read before, is claimed, so one question starts one read.
      """)

      accept([])
      change(filter(expr(is_nil(page_checked_at) and is_nil(support_relationship))))
      change(set_attribute(:page_checked_at, &DateTime.utc_now/0))
    end

    update :claim_picture do
      description("""
      Marks a try at a picture of a site's page for its card. Only a site
      outside the directory, with a tool on record and no picture yet, is
      claimed, at most three times and an hour apart, so a picture that
      failed while the screenshot machine was away is tried again by a later
      question, and questions arriving together start one try.
      """)

      accept([])

      change(
        filter(
          expr(
            is_nil(support_relationship) and is_nil(screenshot_path) and tool_count > 0 and
              picture_attempts < 3 and
              (is_nil(picture_tried_at) or picture_tried_at < ago(1, :hour))
          )
        )
      )

      change(atomic_update(:picture_attempts, expr(picture_attempts + 1)))
      change(set_attribute(:picture_tried_at, &DateTime.utc_now/0))
    end

    update :record_screenshot do
      description("Points the site's card at the picture Patchbay took of its page.")
      accept([:screenshot_path, :screenshot_source_url, :screenshot_captured_at])
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
