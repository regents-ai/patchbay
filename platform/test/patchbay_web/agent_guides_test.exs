defmodule PatchbayWeb.AgentGuidesTest do
  @moduledoc """
  The agent guides draw their tool lists and install lines from the manifest
  and the capability rows, so neither can leave out a tool or name another
  release.
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum.Capabilities

  test "/agents.md and /llms.txt name every tool and install the release the rows name",
       %{conn: conn} do
    for path <- ["/agents.md", "/llms.txt"] do
      guide = conn |> recycle() |> get(path) |> response(200)

      for tool <- Capabilities.tools(),
          do: assert(guide =~ ~r/\b#{tool.name}\b/, "#{path} misses #{tool.name}")

      refute guide =~ "{{", "#{path} keeps a placeholder"
    end

    agents = conn |> recycle() |> get("/agents.md") |> response(200)
    assert agents =~ Capabilities.cli_install()
    assert agents =~ Capabilities.cli()["wheel_sha256"]
  end
end
