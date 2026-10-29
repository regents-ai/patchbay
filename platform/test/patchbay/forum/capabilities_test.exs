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

  # Every hosted description has one shape: purpose first, then when to use
  # it, what it needs (with the refusal for a caller without it), what it
  # changes and the next tool. The two parts help and a model rely on are
  # held here: a purpose to list it under, and the prerequisite its
  # admission really applies. A model at /mcp is never told the page's steps.
  test "every hosted tool states its purpose and its prerequisite" do
    needs = %{
      "none" => "Needs nothing.",
      "paired_agent" => "Needs a signed, paired agent (agent_not_paired)."
    }

    purposes = Map.new(Capabilities.hosted(), &{&1.name, &1.purpose})
    requires = Map.new(Capabilities.hosted(), &{&1.name, &1.requires})

    for tool <- PatchbayWeb.MCP.Tools.list(:native_mcp) do
      assert is_binary(purposes[tool.name]) and purposes[tool.name] != "", tool.name
      assert tool.description =~ Map.fetch!(needs, requires[tool.name]), tool.name
      refute tool.description =~ "prepare_agent_request", tool.name
    end
  end

  # Both addresses state all four MCP hints on every tool they list, each read
  # from the manifest's facts, and keep the page's WebMCP hints to the page.
  test "every hosted tool at both addresses states the four MCP hints its facts give" do
    facts = Map.new(Capabilities.hosted(), &{&1.name, &1})

    for surface <- [:native_mcp, :chatgpt_plugin],
        tool <- PatchbayWeb.MCP.Tools.list(surface),
        fact = facts[tool.name] do
      assert tool.annotations == %{
               readOnlyHint: not fact.state_changing,
               destructiveHint: fact.destructive,
               idempotentHint: fact.idempotent,
               openWorldHint: fact.open_world
             },
             "#{surface} #{tool.name}"

      refute tool.annotations.readOnlyHint and tool.annotations.destructiveHint, tool.name
    end

    # Each post and report adds, and is keyed by its client_request_id, so
    # sending it again is safe; taking back a like or a follow removes it.
    for name <- ~w(ask_question post_reply report_tool_problem reply_to_report) do
      assert %{idempotent: true, destructive: false, open_world: true} = facts[name], name
    end

    for name <- ~w(unlike_post unfollow_scope), do: assert(facts[name].destructive, name)
    for name <- ~w(account_balances account_points), do: refute(facts[name].open_world, name)
  end

  test "every tool's version and the manifest's are whole numbers" do
    assert is_integer(Capabilities.manifest_version()) and Capabilities.manifest_version() >= 1

    for tool <- Capabilities.tools() do
      assert is_integer(tool.version) and tool.version >= 1, "#{tool.name} has no version"

      assert tool.requires in ~w(none browser_session paired_agent profile wallet_signed),
             tool.name

      assert tool.payment in ~w(none moves_usdc holds_credits), tool.name

      assert is_boolean(tool.destructive) and is_boolean(tool.idempotent) and
               is_boolean(tool.open_world),
             tool.name

      refute tool.destructive and not tool.state_changing, "#{tool.name} reads yet destroys"

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
