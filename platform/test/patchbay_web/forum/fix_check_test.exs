defmodule PatchbayWeb.Forum.FixCheckTest do
  @moduledoc """
  The quiet look for WebMCP tools the post form takes: the form asks as an
  address is typed and lists the tools found. After two addresses without
  tools the WebMCP Site Directory is offered; after more than three in an
  hour the connection waits a full hour. An address that cannot be a site,
  or cannot be reached, is not counted against anyone. A connection is
  known by its network.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.PageSite

  setup do
    PageSite.serve(%{
      "/" => PageSite.with_tool("search_docs"),
      "/a" => PageSite.without_tools(),
      "/b" => PageSite.without_tools(),
      "/c" => PageSite.without_tools(),
      "/d" => PageSite.without_tools()
    })
  end

  test "lists the tools found at an address", %{conn: conn} do
    body = conn |> from(address()) |> check("https://docs.example.com/") |> json_response(200)

    assert body == %{
             "status" => "found",
             "said" => "Patchbay found 1 WebMCP tool here.",
             "tools" => [%{"name" => "search_docs", "description" => "The search_docs tool."}],
             "directory" => false
           }
  end

  test "two addresses without tools bring the directory; more than three, a wait", %{conn: conn} do
    address = address()
    ask = fn site -> build_conn() |> from(address) |> check(site) end

    first = ask.("https://docs.example.com/a") |> json_response(200)
    assert %{"status" => "none", "directory" => false} = first
    assert first["said"] =~ "no WebMCP tools at this address"

    # The same address again is not a second one.
    assert %{"directory" => false} = ask.("https://docs.example.com/a") |> json_response(200)
    assert %{"directory" => true} = ask.("https://docs.example.com/b") |> json_response(200)

    html = conn |> from(address) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/sites")
    refute html =~ ~r/id="pb-fix-directory"[^>]*hidden/

    assert %{"status" => "none"} = ask.("https://docs.example.com/c") |> json_response(200)

    limited = ask.("https://docs.example.com/d") |> json_response(429)
    assert limited["status"] == "limited"
    assert limited["said"] =~ "Too many addresses without WebMCP tools"
    assert limited["said"] =~ "Try again in 60 minutes."

    # Waiting means waiting, even for an address with tools.
    assert %{"status" => "limited"} = ask.("https://docs.example.com/") |> json_response(429)

    # Another connection is not held back by this one.
    assert %{"status" => "found"} =
             build_conn()
             |> from(address())
             |> check("https://docs.example.com/")
             |> json_response(200)
  end

  test "an address that is no site, or cannot be reached, is said and never counted", %{
    conn: conn
  } do
    address = address()

    invalid = conn |> from(address) |> check("http://docs.example.com/") |> json_response(422)

    assert invalid == %{
             "status" => "invalid",
             "said" => "The site needs a public https address, like https://example.com/app.",
             "tools" => [],
             "directory" => false
           }

    for _ <- 1..4 do
      missing = build_conn() |> from(address) |> check("https://docs.example.com/nowhere")
      assert %{"status" => "unreachable"} = json_response(missing, 200)
    end

    Application.put_env(:patchbay, :assist_target, resolve: fn _host -> [] end)

    gone =
      build_conn() |> from(address) |> check("https://gone.example.com/") |> json_response(200)

    assert gone["said"] == "That address does not lead to any site."

    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})

    assert %{"status" => "found"} =
             build_conn()
             |> from(address)
             |> check("https://docs.example.com/")
             |> json_response(200)
  end

  test "the page offers the look and a place for the tools", %{conn: conn} do
    html = conn |> from(address()) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="pb-fix-site-check")
    assert html =~ ~s(aria-describedby="pb-fix-site-check")
    assert html =~ ~r/id="pb-fix-tools"[^>]*hidden/
    assert html =~ ~r/id="pb-fix-directory"[^>]*hidden/
  end

  defp check(conn, site_url), do: get(conn, ~p"/fix-check", %{"site_url" => site_url})

  test "an IPv6 connection is counted by its network" do
    assert key("2001:db8:1:2::1") == key("2001:db8:1:2:ffff:ffff:ffff:fffe")
    refute key("2001:db8:1:2::1") == key("2001:db8:1:3::1")
    assert key("::ffff:203.0.113.9") == key("203.0.113.9")
    refute key("203.0.113.9") == key("203.0.113.10")
  end

  defp key(address), do: PatchbayWeb.ClientAddress.visitor_key(from(build_conn(), address))

  defp from(conn, address) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    %{conn | remote_ip: ip}
  end

  defp address, do: "198.51.100.#{System.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}"
end
