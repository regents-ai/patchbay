defmodule Patchbay.Forum.SiteCheck do
  @moduledoc """
  What a site offers agents, as Patchbay last found it: one row per
  registrable domain, whether or not the site has a board.

  Opening a site's page asks for a check when there is none or the last is a
  day old, and "Check again" asks once the last is ten minutes old
  (`due?/2`). Asking (`:request`) only marks the row; the check itself
  (`:run`, `Patchbay.Forum.SiteScan`) is a job on its own queue, so a slow
  site never holds up a page. Asking again while a check is on its way adds
  nothing: the job is one per row. A check that fails is tried three times,
  then recorded as one that could not be done (`:give_up`).

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
  @again_after {10, :minute}

  postgres do
    table("site_checks")
    repo(Patchbay.Repo)
  end

  oban do
    triggers do
      # Run when asked for, never on a sweep: every ask queues its job in
      # the same write.
      trigger :run do
        action(:run)
        queue(:site_checks)
        where(expr(is_nil(checked_at) or checked_at < requested_at))
        max_attempts(3)
        on_error(:give_up)
        lock_for_update?(false)
        scheduler_cron(false)
        worker_module_name(Patchbay.Forum.SiteCheck.Workers.Run)
      end
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:record, ["site_check", :domain])
    publish(:give_up, ["site_check", :domain])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :domain, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: Origin.max_host_length())
    end

    # `Patchbay.Forum.SiteScan`'s findings; nil before the first check and
    # after one that could not be done.
    attribute(:findings, :map, allow_nil?: true, public?: true)

    attribute(:requested_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:checked_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_domain, [:domain])
  end

  actions do
    defaults([:read])

    create :request do
      description("Asks for a check of a site. A site with a check on its way keeps that one.")
      accept([])
      argument(:domain, :string, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_domain)
      upsert_fields([:requested_at])

      change(fn changeset, _context ->
        case Origin.normalize(Ash.Changeset.get_argument(changeset, :domain)) do
          {:ok, domain} ->
            Ash.Changeset.force_change_attribute(changeset, :domain, domain)

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :domain, message: message)
        end
      end)

      change(set_attribute(:requested_at, &DateTime.utc_now/0))
      change(run_oban_trigger(:run))
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
      description("The last try at a check failed: the site reads as not checked just now.")
      accept([])
      change(set_attribute(:findings, nil))
      change(set_attribute(:checked_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Findings are public, and anyone may ask for a check: the page limits
    # how often each visitor does. Running and recording are Patchbay's own.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:request) do
      authorize_if(always())
    end
  end

  @doc """
  Whether opening the page (`:open`) or pressing "Check again" (`:again`)
  should ask for a check: there is none yet, or none on its way and the last
  is older than a day, or ten minutes for "Check again".
  """
  @spec due?(Ash.Resource.record() | nil, :open | :again) :: boolean()
  def due?(nil, _reason), do: true

  def due?(check, reason) do
    {amount, unit} = if reason == :open, do: @fresh_for, else: @again_after

    not pending?(check) and
      DateTime.before?(check.checked_at, DateTime.shift(DateTime.utc_now(), [{unit, -amount}]))
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
