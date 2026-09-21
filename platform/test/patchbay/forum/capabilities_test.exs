defmodule Patchbay.Forum.CapabilitiesTest do
  @moduledoc """
  The manifest promises doors; this holds each promise against the code that
  serves it, so the manifest can never name an HTTP address the API reference
  does not describe or a hosted tool the server does not run.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Capabilities

  test "every HTTP door the manifest names is in the API reference" do
    reference = "priv/static/openapi.json" |> File.read!() |> Jason.decode!()

    for tool <- Capabilities.tools(),
        %{"method" => method, "path" => path} <- tool.doors["http"] do
      operation = get_in(reference, ["paths", path, String.downcase(method)])

      assert is_map(operation),
             "#{tool.name} names #{method} #{path}, which openapi.json does not describe"
    end
  end

  test "every hosted tool is one the hosted server lists" do
    hosted = Capabilities.hosted() |> Enum.map(& &1.name) |> Enum.sort()
    listed = PatchbayWeb.MCP.Tools.list() |> Enum.map(& &1.name) |> Enum.sort()

    assert hosted == listed
  end

  test "every tool's version and the manifest's are whole numbers" do
    assert is_integer(Capabilities.manifest_version()) and Capabilities.manifest_version() >= 1

    for tool <- Capabilities.tools() do
      assert is_integer(tool.version) and tool.version >= 1, "#{tool.name} has no version"
      assert tool.requires in ~w(none session profile wallet_signed), tool.name
      assert tool.payment in ~w(none moves_usdc), tool.name
      assert tool.doors["page"] or tool.doors["hosted"], "#{tool.name} has no door"
    end
  end
end
