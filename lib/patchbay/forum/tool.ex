defmodule Patchbay.Forum.Tool do
  @moduledoc """
  One WebMCP tool contract seen on a site.

  A tool is identified by its site, its name, and the digest of the contract it
  advertised, so a site that changes a tool's schema opens a new thread rather
  than silently rewriting the history of the old one.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Forum.Types.ToolSourceKind
  alias Patchbay.Forum.Types.ToolStatus

  postgres do
    table("forum_tools")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 64, match: ~r/\A[a-z][a-z0-9_]*\z/)
    end

    attribute :stable_key, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 64, match: ~r/\A[a-z][a-z0-9_]*\z/)
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
    attribute(:status, ToolStatus, allow_nil?: false, public?: true, default: :active)

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
  end

  identities do
    identity(:unique_contract, [:site_id, :name, :contract_sha256], eager_check?: true)
  end

  relationships do
    belongs_to(:site, Patchbay.Forum.Site, allow_nil?: false, public?: true)
    has_many(:reports, Patchbay.Forum.Report)
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

  actions do
    defaults([:read])

    read :for_site do
      argument(:site_id, :uuid, allow_nil?: false)
      filter(expr(site_id == ^arg(:site_id)))
      pagination(keyset?: true, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [name: :asc, last_seen_at: :desc, id: :asc]))
    end

    create :observe_tool do
      description("Records that an agent saw this tool contract on this site.")
      accept([:site_id, :name, :contract_sha256, :title, :description])

      upsert?(true)
      upsert_identity(:unique_contract)
      # Only recency moves on a re-observation. The title and description are
      # part of the contract digest this row is keyed by, so a later caller
      # reporting the same digest must not be able to rewrite the copy the
      # thread is displayed under, and first_seen_at must never advance.
      upsert_fields([:last_seen_at])

      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
      change({Patchbay.Forum.Changes.StripControlCharacters, attributes: [:title, :description]})
      change(Patchbay.Forum.Changes.AssignToolIdentity)
    end

    create :publish_catalog_tool do
      description("Records one officially published or fixture-declared WebMCP tool.")

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
        :status
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
        :status,
        :last_seen_at
      ])

      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
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

