defmodule Patchbay.Forum.CapabilitiesTest do
  @moduledoc """
  The manifest promises doors; this holds each promise against the code that
  serves it, so the manifest can never name an HTTP address the API reference
  does not describe or a hosted tool the server does not run.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Capabilities

  test "every HTTP door the manifest names is in the API reference" do
    reference = "priv/public/openapi.json" |> File.read!() |> Jason.decode!()

    for tool <- Capabilities.tools(),
        %{"method" => method, "path" => path} <- tool.doors["http"] do
      operation = get_in(reference, ["paths", path, String.downcase(method)])

      assert is_map(operation),
             "#{tool.name} names #{method} #{path}, which openapi.json does not describe"
    end
  end

  test "every hosted tool is one the hosted server lists" do
    hosted = Capabilities.hosted() |> Enum.map(& &1.name) |> Enum.sort()
    listed = PatchbayWeb.MCP.Tools.list(:native_mcp) |> Enum.map(& &1.name) |> Enum.sort()

    assert hosted == listed
  end

  # A model at /mcp is told only how to sign there, never the page's steps.
  test "a hosted signed tool says to sign the request, without the page's steps" do
    signed = for tool <- Capabilities.hosted(), tool.requires == "paired_agent", do: tool.name

    for tool <- PatchbayWeb.MCP.Tools.list(:native_mcp), tool.name in signed do
      assert String.ends_with?(tool.description, ". Sign the request you send."), tool.name
      refute tool.description =~ "prepare_agent_request", tool.name
    end
  end

  test "every tool's version and the manifest's are whole numbers" do
    assert is_integer(Capabilities.manifest_version()) and Capabilities.manifest_version() >= 1

    for tool <- Capabilities.tools() do
      assert is_integer(tool.version) and tool.version >= 1, "#{tool.name} has no version"

      assert tool.requires in ~w(none browser_session paired_agent profile wallet_signed),
             tool.name

      assert tool.payment in ~w(none moves_usdc holds_credits), tool.name

      assert tool.doors["page"] or tool.doors["hosted"] or tool.doors["http"] != [],
             "#{tool.name} has no door"
    end
  end

  # Where a tool is offered is said twice, as its scope and as its doors; the
  # two must agree, so nothing reads a scope the doors contradict.
  test "every tool's scope agrees with its doors" do
    for tool <- Capabilities.manifest()["tools"] do
      %{"page" => page?, "hosted" => hosted?} = tool["doors"]

      expected =
        cond do
          page? -> "site"
          hosted? -> "hosted"
          String.starts_with?(tool["scope"], "page:") -> tool["scope"]
          tool["authentication"] == "owner_only" -> "owner"
        end

      assert tool["scope"] == expected, tool["name"]
    end
  end

  # A signed tool's last sentence says how to sign it on each surface that
  # offers it, so it names /mcp exactly when the hosted server runs the tool.
  test "every signed tool ends with how to sign it where it is offered" do
    for tool <- Capabilities.manifest()["tools"],
        tool["authentication"] == "siwa_per_request",
        tool["doors"]["page"] do
      surfaces = if tool["doors"]["hosted"], do: "at /mcp or over HTTP", else: "over HTTP"

      assert String.ends_with?(
               tool["description"],
               "Signed: on a page, prepare it with prepare_agent_request, sign that request with " <>
                 "your own SIWA key, then pass input, request and proof; #{surfaces}, sign the request you send."
             ),
             tool["name"]
    end
  end
end
