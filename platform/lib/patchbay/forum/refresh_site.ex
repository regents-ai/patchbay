defmodule Patchbay.Forum.RefreshSite do
  @moduledoc """
  The `:refresh` action of `Patchbay.Forum.Site`, run once a day for every
  site by its trigger: asks for a fresh check of what the site offers agents
  (`Patchbay.Forum.SiteCheck`), whose WebMCP tools land on the site's board,
  and reads the site's official source again. A source that still loads and
  still mentions WebMCP is verified today; one that does not keeps the last
  day it was.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Assist.Target
  alias Patchbay.Forum

  @source_bytes 1024 * 1024
  @redirects 3

  @impl true
  def update(changeset, _opts, _context) do
    site = changeset.data
    now = DateTime.utc_now()

    # Patchbay's own daily work: there is no actor for policies to check.
    Forum.request_site_check!(site.origin, authorize?: false)

    verified_at =
      if source_mentions_webmcp?(site.support_evidence_url), do: now, else: site.last_verified_at

    site
    |> Ash.Changeset.for_update(:record_refresh, %{
      refreshed_at: now,
      last_verified_at: verified_at
    })
    |> Ash.update(authorize?: false)
  end

  @doc "Whether the page at `url` loads and says WebMCP somewhere in it."
  @spec source_mentions_webmcp?(String.t() | nil) :: boolean()
  def source_mentions_webmcp?(nil), do: false

  def source_mentions_webmcp?(url) do
    opts =
      Keyword.merge(Application.get_env(:patchbay, :assist_target, []),
        max_body_bytes: @source_bytes,
        redirects: @redirects
      )

    case Target.get(url, opts) do
      {:ok, %{status: 200, body: body}} -> body |> String.downcase() |> String.contains?("webmcp")
      _unreadable -> false
    end
  end
end
