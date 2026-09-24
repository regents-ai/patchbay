defmodule Patchbay.Forum.SiteCheckTest do
  @moduledoc """
  The first question about a site with tools gives it a gallery card: its
  page's tools are recorded, a picture is taken, and it joins the gallery.
  A site without tools stays off the gallery, and a site's page is read only
  once. A picture that fails is tried again by a later question an hour or
  more on, three tries at most, so an outage of the screenshot machine
  leaves no site without a card for good and no site tried forever.
  """

  use Patchbay.DataCase, async: false

  @moduletag :capture_log

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck
  alias Patchbay.PageSite
  alias Patchbay.Repo

  import Ecto.Query

  @picture "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "

  setup do
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)
    shots_answer(200, @picture)
  end

  # The screenshot machine answers every picture asked for with `status`.
  defp shots_answer(status, body) do
    test = self()

    Application.put_env(:patchbay, :shots_req_options,
      plug: fn conn ->
        {:ok, request, conn} = Plug.Conn.read_body(conn)
        send(test, {:shot, Jason.decode!(request)["url"]})
        Plug.Conn.send_resp(conn, status, body)
      end
    )
  end

  # Moves the site's last try at a picture back past the hour a retry waits.
  defp an_hour_passes(site_id) do
    Repo.update_all(
      from(s in "forum_sites", where: s.id == type(^site_id, :binary_id)),
      set: [picture_tried_at: DateTime.add(DateTime.utc_now(), -61, :minute)]
    )
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

  test "a picture that fails keeps the tools, stays off the gallery, and is taken on a question an hour on" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    shots_answer(503, "away")

    SiteCheck.run(site.id)

    assert_received {:shot, "https://docs.example.com/"}
    assert [%{name: "search_docs"}] = Forum.list_tools_for_site!(site.id).results
    refute site.id in gallery_ids()

    # A question within the hour starts nothing.
    SiteCheck.run(site.id)
    refute_received {:shot, _}

    shots_answer(200, @picture)
    an_hour_passes(site.id)
    SiteCheck.run(site.id)

    assert_received {:shot, "https://docs.example.com/"}
    assert site.id in gallery_ids()
  end

  test "a picture is tried three times at most" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    shots_answer(503, "away")

    for _try <- 1..3 do
      SiteCheck.run(site.id)
      assert_received {:shot, _}
      an_hour_passes(site.id)
    end

    SiteCheck.run(site.id)
    refute_received {:shot, _}
  end
end
