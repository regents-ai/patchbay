defmodule Patchbay.Forum.Tool do
  @moduledoc """
  One WebMCP tool contract seen on a site.

  A tool is identified by its site, its name, and the digest of the contract it
  advertised, so a site that changes a tool's schema opens a new thread rather
  than silently rewriting the history of the old one.

  The site is a registrable domain; `address` is the exact page the contract
  was last seen on, such as `https://developers.openai.com/docs`, and moves
  with `last_seen_at`.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Types.ToolSourceKind

  postgres do
    table("forum_tools")
    repo(Patchbay.Repo)

    custom_indexes do
      # The tool match (`:find`) reads these: a name or title containing the
      # typed words, or a name nearly matching them.
      index(["name public.gin_trgm_ops"],
        name: "forum_tools_name_trgm_index",
        using: "GIN",
        concurrently: true
      )

      index(["title public.gin_trgm_ops"],
        name: "forum_tools_title_trgm_index",
        using: "GIN",
        concurrently: true
      )
    end
  end

  attributes do
    uuid_primary_key(:id)

    # A name is stored exactly as the site published it: `grid-sort` and
    # `Grid.Sort` are different tools, and neither is rewritten.
    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 64, match: Patchbay.Forum.ToolName.shape())
    end

    attribute :stable_key, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 64, match: Patchbay.Forum.ToolName.shape())
    end

    attribute :published_name, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 120)
    end

    attribute :display_name, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 120)
    end

    attribute :contract_sha256, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 64, max_length: 64, match: ~r/\A[0-9a-f]{64}\z/)
    end

    attribute :title, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 120)
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 1000)
    end

    attribute(:protocol_version, :string, allow_nil?: true, public?: true)
    attribute(:input_schema, :map, allow_nil?: true, public?: true)
    attribute(:output_schema, :map, allow_nil?: true, public?: true)
    attribute(:raw_definition, :map, allow_nil?: true, public?: true)
    attribute(:source_kind, ToolSourceKind, allow_nil?: false, public?: true, default: :observed)
    attribute(:source_url, :string, allow_nil?: true, public?: true)

    attribute(:first_seen_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:last_seen_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute :address, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: Origin.max_address_length(), match: ~r/\Ahttps:\/\/\S+\z/)
    end

    # When a check of the site last found this tool on the page it read; empty
    # for a tool known only from what agents saw. Only a tool a check once
    # found can be retired by a later check (`SiteCheck.record_tools/2`).
    attribute(:check_found_at, :utc_datetime_usec, allow_nil?: true)

    # When a check that read the whole page no longer found the tool there;
    # empty while it is offered. Seeing the tool again empties it.
    attribute(:retired_at, :utc_datetime_usec, allow_nil?: true)
  end

  identities do
    identity(:unique_contract, [:site_id, :name, :contract_sha256], eager_check?: true)
  end

  relationships do
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)

    # The public reports about this contract: what moderation holds or redacts
    # is not part of the tally or the history a tool page shows.
    has_many :reports, Patchbay.Forum.Report do
      filter(expr(visibility == :published))
    end
  end

  aggregates do
    count :report_count, :reports do
      description("How many reports have been filed against this contract.")
    end

    count :distinct_session_count, :reports do
      description("""
      How many distinct browser sessions have reported. A session id is chosen
      and sent by the reporting browser and is never verified, so this counts
      claimed reporters, not proven people. Treat it as a weak corroboration
      signal only.
      """)

      field(:browser_session_id)
      uniq?(true)
    end

    count :verified_success_count, :reports do
      filter(expr(verdict == :verified_success))
    end

    count :verified_failure_count, :reports do
      filter(expr(verdict == :verified_failure))
    end

    count :errored_count, :reports do
      filter(expr(verdict == :errored))
    end

    count :unknown_count, :reports do
      filter(expr(verdict == :unknown))
    end

    max(:latest_report_at, :reports, :inserted_at)
  end

  calculations do
    # On a site with no published list: a site in the researched directory
    # keeps its list, since the check records and retires nothing there
    # (`SiteCheck.record_tools/2`).
    calculate(
      :current?,
      :boolean,
      expr(
        if is_nil(site.latest_check_at) do
          not is_nil(site.support_relationship) or is_nil(retired_at)
        else
          last_seen_at >= site.latest_check_at
        end
      ),
      description: """
      Whether the tool is still offered. On a site with a published tool list:
      seen at or after the latest check of that list. On a site in Patchbay's
      researched directory without one: always. On any other site: not
      retired. A check retires a tool it once found on the page it reads and
      no longer finds there, and only when it read the whole page, every
      script on the site's own domain included, and found at least one tool;
      a tool known only from what agents saw is never retired, and a retired
      tool is offered again once it is seen again.
      """
    )
  end

  actions do
    defaults([:read])

    read :for_site do
      argument(:site_id, :uuid, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id)))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [name: :asc, last_seen_at: :desc, id: :asc]))
    end

    read :inventory do
      description("""
      A site's current tools one name at a time, each with its newest version,
      in name order from an optional name onward.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:after_name, :string)
      filter(expr(site_id == ^arg(:site_id) and current?))
      filter(expr(is_nil(^arg(:after_name)) or name > ^arg(:after_name)))
      pagination(offset?: true, default_limit: 20, max_page_size: 20)
      prepare(build(distinct: [:name], sort: [name: :asc, last_seen_at: :desc, id: :asc]))
    end

    read :named do
      description("""
      Which of the given names a site offers as tools now, one entry per name:
      the names a check found on the site's page that its list already holds.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:names, {:array, :string}, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id) and current? and name in ^arg(:names)))
      prepare(build(distinct: [:name], sort: [name: :asc]))
    end

    read :find do
      description("""
      Tools still offered whose name or title contains the words a visitor
      typed, or whose name nearly matches them (a letter or two wrong), one
      entry per site and name, with the site to link it under.
      """)

      argument(:text, :string, allow_nil?: false, constraints: [min_length: 2, max_length: 200])

      filter(expr(current?))
      prepare({Patchbay.Forum.FindText, contains: [:name, :title], near: [:name]})

      prepare(
        build(
          distinct: [:site_id, :name],
          sort: [site_id: :asc, name: :asc, last_seen_at: :desc, id: :asc],
          load: [:site],
          limit: 8
        )
      )

      prepare(Patchbay.Forum.SearchSlots)
    end

    read :for_sitemap do
      description("Every tool with its site, newest version of each name first.")

      prepare(
        build(sort: [site_id: :asc, name: :asc, last_seen_at: :desc, id: :asc], load: [:site])
      )
    end

    read :history do
      argument(:site_id, :uuid, allow_nil?: false)
      argument(:name, :string, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id) and name == ^arg(:name)))
      pagination(keyset?: true, required?: true, default_limit: 26, max_page_size: 26)
      prepare(build(sort: [first_seen_at: :desc, id: :asc]))
    end

    read :missed_by_check do
      description("""
      The tools a check may retire: the ones a check once found on the page
      it has now read whole, still offered, and not among those it found
      there this time.
      """)

      argument(:site_id, :uuid, allow_nil?: false)
      argument(:page_url, :string, allow_nil?: false)
      argument(:found_ids, {:array, :uuid}, allow_nil?: false)

      filter(
        expr(
          site_id == ^arg(:site_id) and address == ^arg(:page_url) and
            not is_nil(check_found_at) and is_nil(retired_at) and
            id not in ^arg(:found_ids)
        )
      )
    end

    create :observe_tool do
      description("Records that an agent saw this tool contract on this site.")
      accept([:site_id, :name, :contract_sha256, :title, :description, :address])

      upsert?(true)
      upsert_identity(:unique_contract)
      # Only recency and the page it was seen on move on a re-observation. The
      # title and description are part of the contract digest this row is
      # keyed by, so a later caller reporting the same digest must not be able
      # to rewrite the copy the thread is displayed under, and first_seen_at
      # must never advance. A retired tool seen again is offered again.
      upsert_fields([:last_seen_at, :address, :retired_at])

      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:title, :description]})
      change(Patchbay.Forum.Changes.AssignToolIdentity)
    end

    create :find_on_page do
      description("""
      Records that a check of the site found this tool contract on the page
      it read: an agent's sighting in every way, and marked as a check's own.
      """)

      accept([:site_id, :name, :contract_sha256, :description, :address])

      upsert?(true)
      upsert_identity(:unique_contract)
      upsert_fields([:last_seen_at, :address, :check_found_at, :retired_at])

      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
      change(set_attribute(:check_found_at, &DateTime.utc_now/0))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:description]})
      change(Patchbay.Forum.Changes.AssignToolIdentity)
    end

    update :retire do
      description("A check that read the whole page no longer found the tool there.")
      accept([])
      change(set_attribute(:retired_at, &DateTime.utc_now/0))
    end

    create :publish_catalog_tool do
      description("""
      Records one officially published or fixture-declared WebMCP tool. The
      caller says when the publication was last checked; writing the row again
      is not itself a check, so the time never advances on its own.
      """)

      accept([
        :site_id,
        :name,
        :contract_sha256,
        :title,
        :description,
        :stable_key,
        :published_name,
        :display_name,
        :protocol_version,
        :input_schema,
        :output_schema,
        :raw_definition,
        :source_kind,
        :source_url,
        :first_seen_at,
        :last_seen_at,
        :address
      ])

      upsert?(true)
      upsert_identity(:unique_contract)

      upsert_fields([
        :title,
        :description,
        :stable_key,
        :published_name,
        :display_name,
        :protocol_version,
        :input_schema,
        :output_schema,
        :raw_definition,
        :source_kind,
        :source_url,
        :last_seen_at,
        :address
      ])

      # Both dates come from the publication being imported: the catalog's
      # checked date for a documented tool, this boot for our own manifest.
      # A contract seen again keeps its first date and moves its last one.
      validate(present([:first_seen_at, :last_seen_at]))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:title, :description]})
      change(Patchbay.Forum.Changes.AssignToolIdentity)
    end
  end

  policies do
    # v0 of the forum is a fully public board: no actor is required.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:observe_tool) do
      authorize_if(always())
    end

    policy action(:publish_catalog_tool) do
      authorize_if(always())
    end
  end
end
