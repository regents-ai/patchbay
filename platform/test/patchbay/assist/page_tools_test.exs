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
    assert %{input_schema: nil, read_only?: false} = search

    hosts = Agent.get(fetched, & &1)
    assert "static.docs.example.org" in hosts
    refute "cdn.elsewhere.net" in hosts
  end

  # keyfleet.ai as it answered on 12 November 2026, cut down to two of its
  # tools: the page loads app.js, which imports the list it signs up, which
  # imports the script the tools are written in.
  @keyfleet_page """
  <html><head>
  <script defer phx-track-static type="module" src="/assets/js/app-639e64e1.js?vsn=d"></script>
  <link rel="modulepreload" href="/assets/js/chunks/chunk-WYBSCXA6.js">
  </head><body></body></html>
  """

  @keyfleet_app """
  import"./chunks/chunk-WYBSCXA6.js";function rs(){let e=document.documentElement.dataset;
  if(!("modelContext"in document)){e.webmcpStatus="unsupported";return}let t;
  window.addEventListener("pageshow",()=>{let i=new AbortController;t=i;let{signal:n}=i;
  import("./chunks/public_tool_list-2YZ2HGI6.js").then(({tools:s})=>{if(!n.aborted)
  return Promise.all(s.map(r=>document.modelContext.registerTool(r,{signal:n})))})})}
  """

  @keyfleet_list """
  import{a as E,b as v,c as I}from"./chunk-EKSAZ6HN.js";import"./chunk-WYBSCXA6.js";
  var H=E.tools,te=H.filter(e=>e.scope==="site").map(e=>({name:e.name,title:e.title,
  description:v(e),inputSchema:e.input_schema,annotations:e.annotations,
  async execute(t,{signal:s}){return I(t,e.input_schema)}}));export{te as tools};
  """

  @keyfleet_tools """
  var u={tools:[{name:"about",title:"About",description:"Read the About page, its title and its Markdown: what Keyfleet is, who uses it and who runs it. No sign-in; changes nothing.",input_schema:{type:"object",properties:{},required:[],additionalProperties:!1},annotations:{readOnlyHint:!0},requires:"none",scope:"site",authentication:"public"},{name:"fleets_list",title:"Fleets",description:"List the fleets. No sign-in; changes nothing.",input_schema:{type:"object",properties:{},required:[],additionalProperties:!1},annotations:{readOnlyHint:!0},requires:"none",scope:"site",authentication:"public"}]};export{u as a};
  """

  test "finds tools written in one script and signed up by another, three imports deep" do
    PageSite.serve(%{
      "/" => @keyfleet_page,
      "/assets/js/app-639e64e1.js" => @keyfleet_app,
      "/assets/js/chunks/chunk-WYBSCXA6.js" => "export const w = 1",
      "/assets/js/chunks/public_tool_list-2YZ2HGI6.js" => @keyfleet_list,
      "/assets/js/chunks/chunk-EKSAZ6HN.js" => @keyfleet_tools
    })

    {:ok, page} = PageTools.page("https://keyfleet.ai/", target_options())

    assert %{complete?: true, tools: [about, fleets]} =
             PageTools.inspect_tools(page, target_options())

    assert about.name == "about"
    assert about.description =~ "Read the About page"
    assert fleets.name == "fleets_list"
  end

  # Tools as sites write them: a parameter's description before the tool's
  # own, tools handed over together with each description before its name,
  # a tool whose words are put together at run time, and one whose schema
  # runs on far past its name.
  @own_descriptions ~S"""
  navigator.modelContext.registerTool({name:"search_products",inputSchema:{type:"object",properties:{query:{type:"string",description:"Words to look for"}},required:["query"]},description:"Search the catalogue for products in stock.",execute:async({query})=>find(query)});
  navigator.modelContext.provideContext({tools:[{description:"Add an item to the cart.",name:"add_to_cart",inputSchema:{type:"object",properties:{sku:{type:"string",description:"The item's SKU"}}},execute:add},{description:"Empty the cart.",name:"clear_cart",inputSchema:{},execute:clear}]});
  navigator.modelContext.registerTool({name:"track_order",inputSchema:{type:"object",properties:{order_id:{type:"string",description:"The order number on the receipt"}}},execute:track});
  navigator.modelContext.registerTool({name: "translate", description: t("translate.help"), inputSchema: {type: "object", properties: {text: {type: "string", description: "The text to translate"}}}, execute});
  """

  test "a tool's description is the one written on the tool, never one of its parameters'" do
    wide =
      ~s|navigator.modelContext.registerTool({name:"export_orders",inputSchema:{type:"object",properties:{| <>
        Enum.map_join(
          1..40,
          ",",
          &~s|field_#{&1}:{type:"string",description:"Field #{&1} of the export."}|
        ) <>
        ~s|}},description:"Export every order as a spreadsheet.",execute:run});|

    assert read_tools(@own_descriptions <> wide) == %{
             "search_products" => "Search the catalogue for products in stock.",
             "add_to_cart" => "Add an item to the cart.",
             "clear_cart" => "Empty the cart.",
             # No words of its own that can be read without running the page.
             "track_order" => "",
             "translate" => "",
             "export_orders" => "Export every order as a spreadsheet."
           }
  end

  # Text written the ways scripts write it: split in two with `+` (here in the
  # middle of a word), with escapes, apostrophes and a line carried on, in a
  # template across two lines, in a template with a value put into it, and
  # holding words that look like a tool's name.
  @written_text ~S"""
  navigator.modelContext.registerTool({
    name: "book_table",
    description: "Book a table for up to eight people. Returns the boo" +
      "king reference and the time it was booked for.",
    inputSchema: {type: "object"},
    execute: async () => ({})
  });
  navigator.modelContext.registerTool({name:"quote_text",description:"Wraps text in \"quotes\" — it’s safe.\tTabs\\slashes \x41 \u{1F600} 😀 and a line \
  carried on.",inputSchema:{},execute:q});
  navigator.modelContext.registerTool({name:'cancel_booking',description:'Cancel a booking you\'ve made; it can\'t be "undone".',inputSchema:{},execute:c});
  navigator.modelContext.registerTool({name:"list_rooms",description:`List the rooms free tonight,
  with their prices.`,inputSchema:{},execute:()=>1});
  navigator.modelContext.registerTool({name:"find_pages",description:`Find pages ${scope ? `in ${scope}` : "everywhere"}, newest first.`,inputSchema:{},execute:find});
  navigator.modelContext.registerTool({name:"get_item",description:"Get one item, for example {name: 'sku-1'}, with its price.",inputSchema:{},execute:g});
  """

  test "a description is read whole, however the code writes it" do
    assert read_tools(@written_text) == %{
             "book_table" =>
               "Book a table for up to eight people. Returns the booking reference and the time it was booked for.",
             "quote_text" =>
               "Wraps text in \"quotes\" — it’s safe.\tTabs\\slashes A 😀 😀 and a line carried on.",
             "cancel_booking" => "Cancel a booking you've made; it can't be \"undone\".",
             "list_rooms" => "List the rooms free tonight,\nwith their prices.",
             # Its words are put together when the page runs.
             "find_pages" => "",
             "get_item" => "Get one item, for example {name: 'sku-1'}, with its price."
           }
  end

  test "a description too long to keep is cut between words and ends with …" do
    words = String.duplicate("Reserve a table tonight. ", 60)

    %{"reserve_table" => kept} =
      read_tools(
        ~s|navigator.modelContext.registerTool({name:"reserve_table",description:"#{words}",inputSchema:{},execute:r});|
      )

    assert String.length(kept) <= 1_000
    assert String.ends_with?(kept, "…")
    assert String.starts_with?(words, String.trim_trailing(kept, "…"))
    assert String.at(words, String.length(kept) - 1) =~ ~r/[\s.]/
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

  test "a form's description is read as the browser reads it, its character references decoded once" do
    page = %{
      url: "https://shop.example/",
      html: """
      <form toolname="ask_team" tooldescription="Questions &amp; answers &mdash; it&#39;s free, &quot;fast&quot; &#x1F600; and &amp;amp; stays"></form>
      <form TOOLNAME='find_rooms' ToolDescription='Rooms &lt;b&gt; tonight' tooldescription='Not this one'></form>
      """,
      cut?: false
    }

    assert page
           |> PageTools.inspect_tools()
           |> Map.fetch!(:tools)
           |> Map.new(&{&1.name, &1.description}) ==
             %{
               "ask_team" => "Questions & answers — it's free, \"fast\" 😀 and &amp; stays",
               "find_rooms" => "Rooms <b> tonight"
             }
  end

  test "keeps only names the board would store, in code and on forms" do
    PageSite.serve(%{
      "/" =>
        PageSite.with_tool("_private") <>
          PageSite.with_tool("3d-view") <>
          ~s(<form toolname="_x" tooldescription="Hidden."></form>)
    })

    assert {:ok, [%{name: "3d-view"}]} =
             PageTools.read("https://bookings.example.com/", target_options())
  end

  test "a read is complete only when the page and every own-site script answer in full" do
    tool = PageSite.with_tool("reserve_table")
    loads = &~s(<script src="/#{&1}"></script>)

    PageSite.serve(%{
      "/" => tool <> loads.("app.js"),
      "/down" => tool <> loads.("down.js"),
      "/big" => tool <> loads.("big.js"),
      "/deep" => tool <> loads.("chain.js"),
      "/lost" => tool <> loads.("broken.js"),
      "/inline" => tool <> ~s(<script type="module">import "/one.js";</script>),
      "/app.js" => ~s(import "./one.js";),
      "/one.js" => "export const one = 1",
      "/down.js" => {503, [], "away"},
      # One byte past the script bound: read up to it, then cut.
      "/big.js" => String.duplicate("x", 2 * 1024 * 1024 + 1),
      # Imports are followed however deep they go.
      "/chain.js" => ~s(import "./a.js";),
      "/a.js" => ~s(import "./b.js";),
      "/b.js" => "export const b = 1",
      # gone.js, two imports deep, is not there.
      "/broken.js" => ~s(import "./c.js";),
      "/c.js" => ~s(import "./gone.js";)
    })

    for {path, complete?} <- [
          {"/", true},
          {"/down", false},
          {"/big", false},
          {"/deep", true},
          {"/lost", false},
          {"/inline", true}
        ] do
      {:ok, page} = PageTools.page("https://bookings.example.com" <> path, target_options())

      assert %{complete?: ^complete?, tools: [%{name: "reserve_table"}]} =
               PageTools.inspect_tools(page, target_options())
    end
  end

  test "discovery puts the directory's tools first and adds what the page signs up" do
    site = Forum.register_site!("https://bookings.example.com")

    Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
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
             Discovery.find("https://nothing.example.net/", target_options())
  end

  defp target_options, do: Application.get_env(:patchbay, :assist_target)

  # The tools a page with `script` written into it signs up, name to description.
  defp read_tools(script) do
    page = %{
      url: "https://shop.example/",
      html: ~s(<html><body><script type="module">#{script}</script></body></html>),
      cut?: false
    }

    page |> PageTools.inspect_tools() |> Map.fetch!(:tools) |> Map.new(&{&1.name, &1.description})
  end
end
