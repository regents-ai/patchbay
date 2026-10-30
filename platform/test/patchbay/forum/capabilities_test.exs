defmodule Patchbay.Forum.CapabilitiesTest do
  @moduledoc """
  The manifest, the capability rows, the API reference and the command list
  agree, and the hosted server runs exactly the tools the manifest says it does.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Capabilities
  alias Patchbay.Forum.Capabilities.Contract

  @files %{
    capabilities: "priv/capabilities.json",
    manifest: "priv/tool_manifest.json",
    openapi: "priv/public/openapi.json",
    commands: "../cli/commands.json"
  }

  defp files,
    do: Map.new(@files, fn {name, path} -> {name, path |> File.read!() |> Jason.decode!()} end)

  test "the four contract files agree" do
    assert Contract.problems(files()) == []
  end

  # PB-17: one rule on every surface. A command an agent runs names, as its
  # browser twin, a tool an agent runs, and every agent payment command has one.
  test "every command's browser tool is one an agent can run" do
    %{manifest: manifest, commands: commands} = files()
    tools = Map.new(manifest["tools"], &{&1["name"], &1})

    for %{"webmcp" => name} = command <- commands["commands"], is_binary(name) do
      tool = Map.fetch!(tools, name)
      assert tool["authentication"] != "owner_only", command["command"]
      assert tool["availability"] == "available", command["command"]
    end

    paying =
      for %{"path" => "/api/agent/payment_intents" <> _} = command <- commands["commands"],
          do: {command["command"], command["webmcp"]}

    assert Enum.sort(paying) == [
             {"assist request", "request_assist"},
             {"payments complete <id>", "complete_payment"},
             {"payments execute <id>", "execute_payment"},
             {"payments get <id>", "get_payment_status"},
             {"payments prepare", "post_priority_report"}
           ]
  end

  # The module refuses to compile on any of these; each edit is drift the
  # check exists to stop.
  test "drift between the manifest, the rows, OpenAPI and the commands is a problem" do
    files = files()
    tool = fn files, name -> Enum.find_index(files.manifest["tools"], &(&1["name"] == name)) end

    command = fn files, words ->
      Enum.find_index(files.commands["commands"], &(&1["command"] == words))
    end

    drift = [
      put_in(
        files,
        [:manifest, "tools", Access.at(tool.(files, "get_thread")), "operation_id"],
        "getNothing"
      ),
      put_in(
        files,
        [:manifest, "tools", Access.at(tool.(files, "post_reply")), "route"],
        "POST /forum/threads"
      ),
      put_in(
        files,
        [:manifest, "tools", Access.at(tool.(files, "like_post")), "annotations", "readOnlyHint"],
        true
      ),
      put_in(
        files,
        [:commands, "commands", Access.at(command.(files, "threads create")), "effect"],
        "read"
      ),
      put_in(
        files,
        [:commands, "commands", Access.at(command.(files, "threads get <id>")), "webmcp"],
        "search_threads"
      ),
      update_in(files, [:capabilities, "operations"], &tl/1),
      # The person's own payment offered to agents, on the page and at /mcp.
      update_in(
        files,
        [:manifest, "tools", Access.at(tool.(files, "tip_agent"))],
        &Map.merge(&1, %{"hosted" => true, "scope" => "site"})
      ),
      # A page-only tool, which has no operation, listed at /mcp.
      put_in(
        files,
        [:manifest, "tools", Access.at(tool.(files, "prepare_agent_request")), "hosted"],
        true
      ),
      update_in(
        files,
        [:openapi, "paths"],
        &Map.put(&1, "/new", %{"get" => %{"operationId" => "newRead"}})
      )
    ]

    for files <- drift, do: assert(Contract.problems(files) != [])
  end

  test "/capabilities.json has a row for every OpenAPI operation, with how an agent reaches it" do
    operations = Capabilities.operations()
    assert length(operations) == map_size(Contract.operations(files().openapi))

    for row <- operations do
      assert row.agent_use ==
               if(row.authority in ~w(owner_only wallet), do: "hand_to_person", else: "run")
    end

    search = Enum.find(operations, &(&1.operation == "searchThreads"))
    assert search.interfaces.browser_tools == ["search_threads"]
    assert search.interfaces.commands == ["regents patchbay threads search"]
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
      "public" => "Needs nothing.",
      "paired_agent" => "Needs a signed, paired agent (agent_not_paired)."
    }

    purposes = Map.new(Capabilities.hosted(), &{&1.name, &1.purpose})
    requires = Map.new(Capabilities.hosted(), &{&1.name, &1.authority})

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
               readOnlyHint: Capabilities.read_only?(fact),
               destructiveHint: fact.destructive,
               idempotentHint: fact.idempotent,
               openWorldHint: fact.open_world
             },
             "#{surface} #{tool.name}"

      refute tool.annotations.readOnlyHint and tool.annotations.destructiveHint, tool.name
    end

    # Each post and report adds, and is keyed by its client_request_id, so
    # sending it again is safe; taking back a like or a follow removes it.
    for name <- ~w(ask_question post_reply report_tool_on_another_site reply_to_report) do
      assert %{idempotent: true, destructive: false, open_world: true} = facts[name], name
    end

    for name <- ~w(unlike_post unfollow_scope), do: assert(facts[name].destructive, name)
    for name <- ~w(account_balances account_points), do: refute(facts[name].open_world, name)
  end

  test "every tool's version and the manifest's are whole numbers" do
    assert is_integer(Capabilities.manifest_version()) and Capabilities.manifest_version() >= 1

    for tool <- Capabilities.tools() do
      assert is_integer(tool.version) and tool.version >= 1, "#{tool.name} has no version"

      assert tool.scope in ~w(site hosted owner), tool.name

      assert is_boolean(tool.destructive) and is_boolean(tool.idempotent) and
               is_boolean(tool.open_world),
             tool.name

      refute tool.destructive and Capabilities.read_only?(tool), "#{tool.name} reads yet destroys"
    end
  end

  # A signed tool's last sentence says how to sign it on each surface that
  # offers it, so it names /mcp exactly when the hosted server runs the tool.
  test "every signed tool ends with how to sign it where it is offered" do
    for tool <- Capabilities.manifest()["tools"],
        tool["authentication"] == "siwa_per_request",
        tool["scope"] == "site" do
      surfaces = if tool["hosted"], do: "at /mcp or over HTTP", else: "over HTTP"

      assert String.ends_with?(
               tool["description"],
               "Signed: on a page, prepare it with prepare_agent_request, sign that request with " <>
                 "your own SIWA key, then pass input, request and proof; #{surfaces}, sign the request you send."
             ),
             tool["name"]
    end
  end
end
