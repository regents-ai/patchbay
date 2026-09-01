defmodule Patchbay.Forum.Site do
  @moduledoc """
  A site an agent has called a WebMCP tool on, identified by its bare host.

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

    attribute(:claimed_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:claim_kind, ClaimKind, allow_nil?: false, public?: true, default: :none)

    timestamps()
  end

  identities do
    identity(:unique_origin, [:origin], eager_check?: true)
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

    create :register_site do
      description("Records a site the first time an agent reports on it.")
      accept([])
      argument(:origin, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_origin)
      # Re-registering an already known origin must change nothing about it.
      upsert_fields([:origin])

      change(Patchbay.Forum.Changes.NormalizeOrigin)
    end
  end

  policies do
    # v0 of the forum is a fully public board: reads and the one named write
    # are open and no actor is required. Any action not named here stays
    # forbidden, so registering is the only way to write to a site.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:register_site) do
      authorize_if(always())
    end
  end
end
