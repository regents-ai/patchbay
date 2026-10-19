defmodule PatchbayDev.WalkClosed do
  @moduledoc """
  In the browser walk, the outside lists a site's check searches (the MCP
  registry, GitHub and npm, `Patchbay.Forum.SiteScan`) are a closed port, like
  the walk's chain nodes: each search fails at once, and the check counts that
  list as unsearched.
  """

  def run(request), do: {request, Req.TransportError.exception(reason: :econnrefused)}
end
