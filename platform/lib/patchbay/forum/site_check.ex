defmodule Patchbay.Forum.SiteCheck do
  @moduledoc """
  What a site offers agents, as Patchbay last found it: one row per
  registrable domain, whether or not the site has a board.

  Opening a site's page asks for a check when there is none, the last read
  no directory pages or the last is a day old, and so do the directory's
  "Update" and Patchbay's own round of the listed sites
  (`Patchbay.Forum.SiteCheckSweep`), by the same rule (`due?/1`); "Refresh this
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
  one. What it found is the one source of a site's tool count (`tools/1`):
  the directory, the board and the JSON at `/sites` all read it.
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
  alias Patchbay.Forum.Tool
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

    # The front page the last finished check read; empty when it read none.
    attribute :page_url, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: Origin.max_address_length())
    end

    # When the last check read that page whole, every script on the site's
    # own domain included; empty when it read it in part or not at all, and
    # after a check that could not be done.
    attribute(:page_read_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    timestamps()
  end

  calculations do
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

    # Whether the last finished check found a WebMCP tool on the front page or
    # on any page the directory lists: the rule `tools/1` counts by.
    calculate(
      :found_tools?,
      :boolean,
      expr(
        fragment(
          "coalesce(jsonb_path_exists(?, '$.webmcp[*]') or jsonb_path_exists(?, '$.directory.*.tools[*]'), false)",
          findings,
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

    read :due_again do
      description("""
      The checks of `domains` that are due again, the longest unchecked first:
      none on its way, and the last either read no directory pages or is a
      day old. The same rule as `due?/1` and the `:request` upsert condition.
      """)

      argument(:domains, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          domain in ^arg(:domains) and not is_nil(checked_at) and requested_at <= checked_at and
            (is_nil(get_path(findings, ["directory"])) or checked_at <= ago(1, :day))
        )
      )

      prepare(build(select: [:domain], sort: [checked_at: :asc]))
    end

    read :without_tools do
      description("""
      Checks that found no WebMCP tool, on the front page or on any directory
      page they read, each with the pages it read: the directory leaves out
      the sites whose every page is among them.
      """)

      filter(
        expr(fragment("jsonb_typeof(? -> 'directory') = 'object'", findings) and not found_tools?)
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
      description("""
      Keeps a finished check's findings, the front page it read and, when it
      read that page whole, when.
      """)

      accept([:findings, :page_url])
      argument(:page_whole?, :boolean, allow_nil?: false, default: false)
      require_atomic?(false)

      change(fn changeset, _context ->
        now = DateTime.utc_now()
        whole? = Ash.Changeset.get_argument(changeset, :page_whole?)

        changeset
        |> Ash.Changeset.force_change_attribute(:checked_at, now)
        |> Ash.Changeset.force_change_attribute(:page_read_at, if(whole?, do: now))
      end)
    end

    update :give_up do
      require_atomic?(false)
      description("The last try at a check failed: the site reads as not checked just now.")
      accept([])

      # The directory's pages keep their last reads; a site none were read for
      # still comes due a day later (`due?/1`), not at once.
      change(fn changeset, _context ->
        findings = changeset.data.findings || %{}

        Ash.Changeset.force_change_attribute(
          changeset,
          :findings,
          findings |> Map.put("failed", true) |> Map.put_new("directory", %{})
        )
      end)

      change(set_attribute(:checked_at, &DateTime.utc_now/0))
      change(set_attribute(:page_read_at, nil))
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
  The WebMCP tools Patchbay's own check found for a site, the one count every
  page shows: on its front page, then on every page the directory lists for
  it that the check read whole, each name once, with the page it was found on
  and its description. Nil until a check has finished: the site is not
  checked. A check that could not be done keeps the last finished one's tools.
  """
  @spec tools(Ash.Resource.record() | nil) :: [map()] | nil
  def tools(%{findings: %{"webmcp" => front, "directory" => directory}, page_url: page_url}) do
    on_front = Enum.map(front, &Map.put(&1, "address", page_url))

    Enum.uniq_by(
      on_front ++ listed(directory, directory |> Map.keys() |> Enum.sort()),
      & &1["name"]
    )
  end

  def tools(_check), do: nil

  @doc """
  The tools the check found on `pages` alone, some of the pages the directory
  lists, by the rule of `tools/1`: a directory row for another address on the
  site, such as a product's own, counts only its own pages.
  """
  @spec tools(Ash.Resource.record() | nil, [String.t()]) :: [map()] | nil
  def tools(%{findings: %{"webmcp" => _front, "directory" => directory}}, pages),
    do: directory |> listed(pages) |> Enum.uniq_by(& &1["name"])

  def tools(_check, _pages), do: nil

  defp listed(directory, pages),
    do: Enum.flat_map(pages, &(get_in(directory, [&1, "tools"]) || []))

  @doc """
  Records the WebMCP tools a check found on the site's board, on the front
  page and on every page the directory lists, keyed by exactly the words each
  page published them with, seen at the page they were found on and marked
  as found by a check. Where this check read a page whole and found at least
  one tool there, it then retires the tools an earlier check found there and
  this one did not; a tool known only from what agents saw stays, as does
  everything after a partial read or one that found no tools, since a page
  may put its tools together where the reader cannot see them.
  """
  @spec record_tools(Ash.Resource.record(), Ash.Resource.record()) :: :ok
  def record_tools(site, %{findings: %{"webmcp" => _front, "directory" => _pages}} = check) do
    reads = page_reads(check)
    whole = for {address, _tools, true} <- reads, into: MapSet.new(), do: address

    reads
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.group_by(& &1["address"])
    |> Enum.each(fn {address, tools} ->
      found = tools |> Enum.uniq_by(& &1["name"]) |> Enum.map(&find_tool!(site, &1))
      if MapSet.member?(whole, address), do: retire_missed(site, address, found)
    end)
  end

  def record_tools(_site, _check), do: :ok

  # Each page the check has tools from, with them and whether this check read
  # it whole: the front page, and the directory's pages with a whole read,
  # each read in this check when its read is no older than the request.
  defp page_reads(%{findings: %{"webmcp" => front, "directory" => directory}} = check) do
    on_front =
      if is_binary(check.page_url),
        do: [
          {check.page_url, Enum.map(front, &Map.put(&1, "address", check.page_url)),
           not is_nil(check.page_read_at)}
        ],
        else: []

    listed =
      for {_url, %{"page_url" => address, "tools" => tools, "checked_at" => at}} <- directory,
          do: {address, tools, not DateTime.before?(timestamp(at), check.requested_at)}

    on_front ++ listed
  end

  defp timestamp(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  # Patchbay's own background work: there is no actor for policies to check.
  defp find_tool!(site, %{"name" => name, "address" => address} = tool) do
    description = tool["description"]
    contract = %{"name" => name, "title" => nil, "description" => description}

    Forum.find_tool_on_page!(
      %{
        site_id: site.id,
        name: name,
        contract_sha256: contract |> CanonicalJSON.encode() |> Digest.sha256(),
        description: description,
        address: address
      },
      authorize?: false
    )
  end

  # Patchbay's own background work: there is no actor for policies to check.
  defp retire_missed(site, address, found) do
    Tool
    |> Ash.Query.for_read(
      :missed_by_check,
      %{site_id: site.id, page_url: address, found_ids: Enum.map(found, & &1.id)},
      authorize?: false
    )
    |> Ash.bulk_update!(:retire, %{}, authorize?: false)
  end
end
