defmodule Patchbay.Forum.RunSiteCheck do
  @moduledoc """
  The `:run` action of `Patchbay.Forum.SiteCheck`: checks one site with
  `Patchbay.Forum.SiteScan`, keeps the findings, and records the WebMCP tools
  found on the site's board when it has one. Its job is the `:run` trigger.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck
  alias Patchbay.Forum.SiteScan

  @impl true
  def update(changeset, _opts, _context) do
    check = changeset.data
    findings = SiteScan.findings(check.domain, Application.get_env(:patchbay, :assist_target, []))

    # Patchbay's own job: it answers to nobody's request.
    with {:ok, check} <- Forum.record_site_check(check, %{findings: findings}, authorize?: false) do
      case Forum.get_site_by_origin(check.domain, authorize?: false) do
        {:ok, site} -> SiteCheck.record_tools(site, check)
        {:error, _no_board} -> :ok
      end

      {:ok, check}
    end
  end
end
