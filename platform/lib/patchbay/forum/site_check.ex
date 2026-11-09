defmodule Patchbay.Forum.SiteCheck do
  @moduledoc """
  What a site offers agents, as Patchbay last found it: one row per
  registrable domain, whether or not the site has a board.

  Opening a site's page asks for a check when there is none, the last read
  no directory pages or the last is a day old, and so does the directory's
  "Update" (`due?/1`); "Refresh this
  site" asks for one however recent the last is (`:refresh`), at most once a
  day for the site's picture. Asking only marks the row; the check itself
  (`:run`, `Patchbay.Forum.SiteScan`) is a job on its own queue, so a slow
  site never holds up a page. Asking again while a check is on its way adds
  nothing: the job is one per row. A check that fails is tried three times,
  then recorded as one that could not be done (`:give_up`). Every ask queues
  its job in the same write; a sweep every ten minutes queues a job only for
  a check still on its way whose job is gone, so a page never shows a check
  under way for ever.

  A finished check is told to open pages on `"site_check:<domain>"`, and the
  WebMCP tools it found are recorded on the site's board when the site has
  one outside the researched directory.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban]

  import Ash.Expr

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest

  @fresh_for {1, :day}

  postgres do
    table("site_checks")
    repo(Patchbay.Repo)
  end

  oban do
    triggers do
      # Every ask queues its job in the same write. The ten-minute sweep only
      # picks up a check still on its way whose job is gone, such as one
      # discarded on its last attempt before `:give_up` could run; a check
      # whose job is waiting or running is left to it, one job per row.
      trigger :run do
        action(:run)
        queue(:site_checks)
        where(expr(is_nil(checked_at) or checked_at < requested_at))
        max_attempts(3)
        on_error(:give_up)
        lock_for_update?(false)
        scheduler_cron("*/10 * * * *")
        worker_module_name(Patchbay.Forum.SiteCheck.Workers.Run)
        scheduler_module_name(Patchbay.Forum.SiteCheck.Schedulers.Run)
      end
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:record, ["site_check", :domain])
    publish(:give_up, ["site_check", :domain])
    # Every check, for the directory's hidden sites (`Patchbay.Forum.HiddenSites`).
    publish(:record, ["site_checks"])
    publish(:give_up, ["site_checks"])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :domain, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: Origin.max_host_length())
    end

    # The last findings; nil before the first check. Failures keep previous findings.
    attribute(:findings, :map, allow_nil?: true, public?: true)

    attribute(:requested_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:checked_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    timestamps()
  end

  calculations do
    # The front page the last finished check read, or nil when it read none.
    calculate(:read_page_url, :string, expr(fragment("(? ->> 'page_url')", findings)))

    # When the last finished check read the whole front page, every script
    # on the site's own domain included (`"page_complete"`), and found at
    # least one tool there; nil otherwise, and for checks recorded before the
    # flag existed. A tool last seen on that page before then is no longer
    # offered there (`Patchbay.Forum.Tool`'s `current?`). A page whose tools
    # the reader cannot see, being put together at run time, retires nothing.
    calculate(
      :page_read_at,
      :utc_datetime_usec,
      expr(
        if not is_nil(read_page_url) and
             fragment(
               "(? -> 'failed') IS DISTINCT FROM 'true'::jsonb AND (? -> 'page_complete') = 'true'::jsonb AND (? -> 'webmcp') @> '[{}]'::jsonb",
               findings,
               findings,
               findings
             ) do
          checked_at
        end
      )
    )

    # The directory pages the last check read in full, with their tool lists.
    calculate(
      :read_directory_pages,
      {:array, :string},
      expr(
        fragment(
          "array(select key from jsonb_each(? -> 'directory') where jsonb_typeof(value -> 'tools') = 'array')",
          findings
        )
      )
    )
  end

  identities do
    identity(:unique_domain, [:domain])
  end

  actions do
    defaults([:read])

    read :asked_domains do
      description("Every domain a check has been asked for, whatever became of it.")
      prepare(build(select: [:domain]))
    end

    read :without_directory_tools do
      description("""
      Checks that found no WebMCP tool on any directory page they read, each
      with the pages it read: the directory leaves out the sites whose every
      page is among them.
      """)

      filter(
        expr(
          fragment(
            "jsonb_typeof(? -> 'directory') = 'object' and not jsonb_path_exists(?, '$.directory.*.tools[*]')",
            findings,
            findings
          )
        )
      )

      prepare(build(select: [:domain], load: [:read_directory_pages]))
    end

    create :request do
      description("Asks for a check of a site. A site with a check on its way keeps that one.")
      accept([])
      argument(:domain, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_domain)
      upsert_fields([:requested_at])

      upsert_condition(
        expr(
          not is_nil(checked_at) and requested_at <= checked_at and
            (is_nil(get_path(findings, ["directory"])) or checked_at <= ago(1, :day))
        )
      )

      return_skipped_upsert?(true)
      change(Patchbay.Forum.Changes.AskForCheck)
    end

    create :refresh do
      description("""
      Asks for a new check of a site however recent the last one is: "Refresh
      this site", which the site's page allows once a day. A site with a
      check on its way keeps that one.
      """)

      accept([])
      argument(:domain, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_domain)
      upsert_fields([:requested_at])
      upsert_condition(expr(not is_nil(checked_at) and requested_at <= checked_at))
      return_skipped_upsert?(true)
      change(Patchbay.Forum.Changes.AskForCheck)
    end

    update :run do
      description("""
      Checks the site and records what it offers. It reads the site and lists
      elsewhere, so nothing here holds a transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Forum.RunSiteCheck)
    end

    update :record do
      description("Keeps a finished check's findings.")
      accept([:findings])
      change(set_attribute(:checked_at, &DateTime.utc_now/0))
    end

    update :give_up do
      require_atomic?(false)
      description("The last try at a check failed: the site reads as not checked just now.")
      accept([])

      change(fn changeset, _context ->
        findings = changeset.data.findings || %{}

        directory =
          Map.new(findings["directory"] || %{}, fn {url, snapshot} ->
            {url, Map.put(snapshot, "failed", true)}
          end)

        Ash.Changeset.force_change_attribute(
          changeset,
          :findings,
          findings |> Map.put("failed", true) |> Map.put("directory", directory)
        )
      end)

      change(set_attribute(:checked_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Findings are public, and anyone may ask for a check: the page limits
    # how often each visitor does. Running and recording are Patchbay's own.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:request, :refresh]) do
      authorize_if(always())
    end
  end

  @doc """
  Whether opening the page or the directory's "Update" should ask for a
  check: there is none yet, or none on its way and the last either read no
  directory pages or is at least 24 hours old. The same rule as the
  `:request` upsert condition, which enforces it again at the write.
  """
  @spec due?(Ash.Resource.record() | nil) :: boolean()
  def due?(nil), do: true

  def due?(check) do
    not pending?(check) and (is_nil((check.findings || %{})["directory"]) or expired?(check))
  end

  defp expired?(check) do
    {amount, unit} = @fresh_for

    DateTime.compare(check.checked_at, DateTime.shift(DateTime.utc_now(), [{unit, -amount}])) !=
      :gt
  end

  @doc "Whether a check is on its way."
  @spec pending?(Ash.Resource.record()) :: boolean()
  def pending?(check),
    do: is_nil(check.checked_at) or DateTime.before?(check.checked_at, check.requested_at)

  @doc """
  Records the WebMCP tools a check found on the site's board, the way an
  agent's sighting of a tool is recorded: keyed by exactly the words the page
  published it with, seen at the page that was read. A site in the
  researched directory keeps the directory's list.
  """
  @spec record_tools(Ash.Resource.record(), Ash.Resource.record()) :: :ok
  def record_tools(%{support_relationship: nil} = site, %{
        findings: %{"page_url" => page_url, "webmcp" => tools}
      })
      when is_binary(page_url) do
    Enum.each(tools, fn %{"name" => name, "description" => description} ->
      contract = %{"name" => name, "title" => nil, "description" => description}

      # Patchbay's own background work: there is no actor for policies to check.
      Forum.observe_tool!(
        %{
          site_id: site.id,
          name: name,
          contract_sha256: contract |> CanonicalJSON.encode() |> Digest.sha256(),
          description: description,
          address: page_url
        },
        authorize?: false
      )
    end)
  end

  def record_tools(_site, _check), do: :ok
end
