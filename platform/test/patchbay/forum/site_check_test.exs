defmodule Patchbay.Forum.SiteCheckTest do
  @moduledoc """
  The first question about a site with tools gives it a gallery card: its
  page's tools are recorded, a picture is taken, and it joins the gallery.
  A site without tools stays off the gallery, and a site's page is read only
  once.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck
  alias Patchbay.PageSite

  @picture "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "

  setup do
    test = self()
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)

    Application.put_env(:patchbay, :shots_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:shot, Jason.decode!(body)["url"]})
        Plug.Conn.send_resp(conn, 200, @picture)
      end
    )

    :ok
  end

  defp gallery_ids, do: Enum.map(Forum.list_gallery_sites!().results, & &1.id)

  test "a site whose page signs up a tool gets its tools, a picture and a gallery place, once" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    refute site.id in gallery_ids()

    SiteCheck.run(site.id)

    assert_received {:shot, "https://docs.example.com/"}
    assert [%{name: "search_docs"}] = Forum.list_tools_for_site!(site.id).results
    assert {:ok, %{image: @picture}} = Forum.get_site_screenshot(site.id)
    assert "/site-screenshots/" <> _ = Ash.get!(Forum.Site, site.id).screenshot_path
    assert site.id in gallery_ids()

    # A later question about the same site reads nothing and takes no picture.
    SiteCheck.run(site.id)
    refute_received {:shot, _}
  end

  test "a site without tools gets no picture and stays off the gallery" do
    PageSite.serve(%{"/" => PageSite.without_tools()})
    site = Forum.register_site!("plain.example.com")

    SiteCheck.run(site.id)

    refute_received {:shot, _}
    assert {:error, _none} = Forum.get_site_screenshot(site.id)
    refute site.id in gallery_ids()
  end
end
