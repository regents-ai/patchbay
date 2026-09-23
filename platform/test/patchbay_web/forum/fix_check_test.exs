defmodule PatchbayWeb.Forum.FixCheckTest do
  @moduledoc """
  The quiet look for WebMCP tools a free fix takes: the form asks as an
  address is typed, and the fix asks again when it is pressed. A free fix is
  kept, not spent, on an address without tools; after two such addresses the
  WebMCP Site Directory is offered; after more than three in an hour the
  connection waits a full hour. An address that cannot be a site, or cannot be reached, is not
  counted against anyone.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Assist
  alias Patchbay.PageSite

  @form %{
    "goal" => "Search the docs for the Responses API",
    "expected_result" => "A link to the right page",
    "sign_in" => "none"
  }

  setup do
    old_assist = Application.get_env(:patchbay, :assist)
    Application.put_env(:patchbay, :assist, pay_to_address: "0x" <> String.duplicate("d", 40))
    on_exit(fn -> Application.put_env(:patchbay, :assist, old_assist) end)

    PageSite.serve(%{
      "/" => PageSite.with_tool("search_docs"),
      "/a" => PageSite.without_tools(),
      "/b" => PageSite.without_tools(),
      "/c" => PageSite.without_tools(),
      "/d" => PageSite.without_tools()
    })
  end

  test "names the tools found at an address", %{conn: conn} do
    body = conn |> from(address()) |> check("https://docs.example.com/") |> json_response(200)

    assert body == %{
             "status" => "found",
             "said" => "Patchbay found 1 WebMCP tool here: search_docs.",
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
    assert html =~ ~s(href="https://webmcp.com/")
    refute html =~ ~r/id="pb-fix-directory"[^>]*hidden/

    assert %{"status" => "none"} = ask.("https://docs.example.com/c") |> json_response(200)

    limited = ask.("https://docs.example.com/d") |> json_response(429)
    assert limited["status"] == "limited"
    assert limited["said"] =~ "Too many addresses without WebMCP tools"
    assert limited["said"] =~ "Try again in 60 minutes."

    # Waiting means waiting, even for an address with tools, and even for the fix itself.
    assert %{"status" => "limited"} = ask.("https://docs.example.com/") |> json_response(429)

    refused =
      build_conn()
      |> from(address)
      |> post(~p"/fixes", %{"fix" => fix("https://docs.example.com/")})

    assert html_response(refused, 200) =~ "Too many addresses without WebMCP tools"

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

  test "a free fix at an address without tools is kept, and one with tools starts", %{conn: conn} do
    address = address()

    refused =
      conn |> from(address) |> post(~p"/fixes", %{"fix" => fix("https://docs.example.com/a")})

    html = html_response(refused, 200)

    assert html =~
             "Patchbay found no WebMCP tools at this address, so a free fix cannot start here."

    assert html =~ ~s(value="https://docs.example.com/a")
    assert html =~ ~s(data-pb-fix-mode="free")
    assert html =~ "1 free fix left today from this connection"

    started =
      build_conn()
      |> from(address)
      |> post(~p"/fixes", %{"fix" => fix("https://docs.example.com/")})

    assert "/fixes/" <> id = redirected_to(started)
    # Read as Patchbay itself, to check what was written.
    assert {:ok, %{site_url: "https://docs.example.com/"}} = Assist.get_run(id, authorize?: false)
  end

  test "the page offers the look only while the fix is free", %{conn: conn} do
    html = conn |> from(address()) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="pb-fix-site-check")
    assert html =~ ~s(aria-describedby="pb-fix-site-check")
    assert html =~ ~r/id="pb-fix-directory"[^>]*hidden/
  end

  defp check(conn, site_url), do: get(conn, ~p"/fix-check", %{"site_url" => site_url})

  defp fix(site_url), do: Map.put(@form, "site_url", site_url)

  defp from(conn, address), do: put_req_header(conn, "fly-client-ip", address)

  defp address, do: "198.51.100.#{System.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}"
end
