defmodule Patchbay.Assist.PageToolsTest do
  @moduledoc """
  The WebMCP tools a page writes into its code, read without running it: in
  the page, in the scripts it loads from its own site and in the modules
  those import, and on forms marked as tools. Scripts from other sites are
  never fetched, and what the site answers is only ever read.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Assist.Discovery
  alias Patchbay.Assist.PageTools
  alias Patchbay.Forum
  alias Patchbay.PageSite

  @bundle """
  import{n as H}from"./router.js";const t={name:"search_docs",title:"Search",
  description:"Search the docs. Use lookup_page on a result \\u2014 then read it.",
  inputSchema:{type:"object",properties:{query:{type:"string"}}},execute:async e=>H(e)};
  const config={name:"docs-site",version:"1"};
  navigator.modelContext.registerTool(t,{signal:n})
  """

  @router """
  export const n=1;const tool={"name":"lookup_page","description":"Read one page.",
  "inputSchema":{}};navigator.modelContext.registerTool(tool)
  """

  @page """
  <html><head>
  <script type="module" src="/_astro/WebMcp.js"></script>
  <script src="https://cdn.elsewhere.net/chat.js"></script>
  <link rel="modulepreload" href="https://static.docs.example.org/pre.js">
  </head><body>
  <form toolname="send_feedback" tooldescription="Tell the team what went wrong.">
  </form></body></html>
  """

  test "reads tools from the page's own scripts, their imports and its forms, never from elsewhere" do
    fetched = start_supervised!({Agent, fn -> [] end})

    PageSite.serve(%{
      "/" => @page,
      "/_astro/WebMcp.js" => @bundle,
      "/_astro/router.js" => @router,
      "/pre.js" => "export const x = 1"
    })

    # Every fetch is written down, to see which addresses were asked for.
    target = Application.get_env(:patchbay, :assist_target)
    [plug: serve] = target[:req_options]

    Application.put_env(:patchbay, :assist_target,
      resolve: fn host ->
        Agent.update(fetched, &[host | &1])
        target[:resolve].(host)
      end,
      req_options: [plug: serve]
    )

    assert {:ok, tools} = PageTools.read("https://docs.example.org/", target_options())

    assert Enum.map(tools, & &1.name) |> Enum.sort() ==
             ["lookup_page", "search_docs", "send_feedback"]

    search = Enum.find(tools, &(&1.name == "search_docs"))
    assert search.description == "Search the docs. Use lookup_page on a result — then read it."
    assert %{input_schema: nil, destructive?: false} = search

    hosts = Agent.get(fetched, & &1)
    assert "static.docs.example.org" in hosts
    refute "cdn.elsewhere.net" in hosts
  end

  test "follows a redirect to the page, and says why a page cannot be read" do
    PageSite.serve(%{
      "/" => {301, [{"location", "/docs"}], ""},
      "/docs" => PageSite.with_tool("reserve_table"),
      "/loop" => {302, [{"location", "/loop"}], ""}
    })

    assert {:ok, [%{name: "reserve_table"}]} =
             PageTools.read("https://bookings.example.com/", target_options())

    assert {:error, :unreachable} =
             PageTools.read("https://bookings.example.com/missing", target_options())

    assert {:error, :unreachable} =
             PageTools.read("https://bookings.example.com/loop", target_options())

    Application.put_env(:patchbay, :assist_target, resolve: fn _host -> [{10, 0, 0, 1}] end)

    assert {:error, :not_public} =
             PageTools.read("https://bookings.example.com/", target_options())
  end

  test "a page with no tool code, or code that names things without signing up tools, has none" do
    PageSite.serve(%{
      "/" => PageSite.without_tools(),
      "/names" => ~s(<script>const a = {name: "menu", description: "Menu"}; registerTool</script>)
    })

    assert {:ok, []} = PageTools.read("https://bookings.example.com/", target_options())
    assert {:ok, []} = PageTools.read("https://bookings.example.com/names", target_options())
  end

  test "discovery puts the directory's tools first and adds what the page signs up" do
    site = Forum.register_site!("https://bookings.example.com")

    Forum.observe_tool!(%{
      site_id: site.id,
      name: "reserve_table",
      contract_sha256: String.duplicate("a", 64),
      description: "From an agent's report."
    })

    PageSite.serve(%{
      "/" => PageSite.with_tool("reserve_table") <> PageSite.with_tool("cancel_booking"),
      "/empty" => PageSite.without_tools()
    })

    assert {:in_pages, [reserve, cancel]} =
             Discovery.find("https://bookings.example.com/", target_options())

    assert {reserve.name, reserve.description} == {"reserve_table", "From an agent's report."}
    assert cancel.name == "cancel_booking"

    PageSite.serve(%{"/" => PageSite.without_tools()})

    assert {:unlisted, :no_tools_found} =
             Discovery.find("https://nothing.example.com/", target_options())
  end

  defp target_options, do: Application.get_env(:patchbay, :assist_target)
end
