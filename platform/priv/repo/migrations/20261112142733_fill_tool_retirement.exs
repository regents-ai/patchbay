defmodule Patchbay.Repo.Migrations.FillToolRetirement do
  @moduledoc """
  Fills, once, the four empty columns `ToolRetirement` added, from what each
  site's check already keeps, so every site lists the same tools as before
  and its next check can retire the tools an earlier check found.

  On every site's check: the front page it read (`page_url`), taken from its
  stored findings, and when it read that page whole (`page_read_at`), which is
  its check time when the findings name a page, did not fail, read the page and
  every script on the site's own domain in full, and found at least one tool.

  On the tools of a site outside the researched directory that sit on the page
  its check read: `check_found_at`, the check time, for each tool whose name
  the check found there; and, on such a site with no published list,
  `retired_at`, the time the check read the page whole, for each tool last seen
  before then. Those are the tools the site's list stopped showing.

  It writes only these four columns, deletes nothing and changes no other
  column. The counts before and after are printed in the release step.
  """

  use Ecto.Migration

  # It gives up after five seconds rather than hold the shared database's other
  # sites behind a lock, as `ToolRetirement` does; run migrate again.
  def up do
    schema = prefix() || "public"

    execute("SET LOCAL lock_timeout = '5s'")
    flush()
    IO.puts("tool retirement fill, before: " <> counts(schema))

    # The front page the check read, as the findings stored it.
    execute("""
    UPDATE #{schema}.site_checks
    SET page_url = findings ->> 'page_url'
    WHERE findings ->> 'page_url' IS NOT NULL
    """)

    # SiteCheck's `page_read_at` calculation as it stood: a page read, not
    # failed, read whole, and at least one tool found on it.
    execute("""
    UPDATE #{schema}.site_checks
    SET page_read_at = checked_at
    WHERE (findings ->> 'page_url') IS NOT NULL
      AND (findings -> 'failed') IS DISTINCT FROM 'true'::jsonb
      AND (findings -> 'page_complete') = 'true'::jsonb
      AND (findings -> 'webmcp') @> '[{}]'::jsonb
    """)

    # A tool reaches its site's check as Site's `site_check` does: the check's
    # domain is the site's origin. A check found a tool by its name on the page
    # it read; the contract digest is not something SQL can work out.
    execute("""
    UPDATE #{schema}.forum_tools AS tool
    SET check_found_at = site_check.checked_at
    FROM #{schema}.forum_sites AS site
    JOIN #{schema}.site_checks AS site_check ON site_check.domain = site.origin
    WHERE tool.site_id = site.id
      AND site.support_relationship IS NULL
      AND tool.address = site_check.page_url
      AND site_check.findings -> 'webmcp' @> jsonb_build_array(jsonb_build_object('name', tool.name))
    """)

    # The tools Tool's `current?` hid until now: on a site with no published
    # list (Site's `latest_check_at`, the newest official tool, is empty) and
    # outside the researched directory, on the page the check read whole, and
    # last seen before it did.
    execute("""
    UPDATE #{schema}.forum_tools AS tool
    SET retired_at = site_check.page_read_at
    FROM #{schema}.forum_sites AS site
    JOIN #{schema}.site_checks AS site_check ON site_check.domain = site.origin
    WHERE tool.site_id = site.id
      AND site.support_relationship IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM #{schema}.forum_tools AS listed
        WHERE listed.site_id = site.id AND listed.source_kind = 'official'
      )
      AND site_check.page_read_at IS NOT NULL
      AND tool.address = site_check.page_url
      AND tool.last_seen_at < site_check.page_read_at
    """)

    flush()
    IO.puts("tool retirement fill, after: " <> counts(schema))
  end

  # Nothing to undo here: `ToolRetirement`'s `down` drops the four columns, and
  # what this filled goes with them.
  def down, do: :ok

  defp counts(schema) do
    %{rows: [[checks, pages, whole]]} =
      repo().query!(
        "SELECT count(*), count(page_url), count(page_read_at) FROM #{schema}.site_checks"
      )

    %{rows: [[tools, found, retired]]} =
      repo().query!(
        "SELECT count(*), count(check_found_at), count(retired_at) FROM #{schema}.forum_tools"
      )

    "site_checks #{checks} (page_url #{pages}, page_read_at #{whole}), " <>
      "forum_tools #{tools} (check_found_at #{found}, retired_at #{retired})"
  end
end
