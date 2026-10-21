defmodule PatchbayWeb.SitemapController do
  @moduledoc """
  Every indexable page with the time it last changed: the fixed pages (with the
  troubleshooting pages, each incident's page, and the motion lab while the
  showcase is public), each site, each tool, and the
  published threads. Bounded, so a crawler never
  waits on the whole board at once.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Incidents
  alias PatchbayWeb.Forum.Troubleshooting

  @static ~w(/ /sites /questions /priority /start /dots /muse /grokbot /hermes /claude /agent-setup /help /webmcp /docs /about /contact /privacy /terms /blog /changelog /offers /offers/how-it-works /test-me /jev /wallet-bench/how-it-works /incidents)
  @threads 2_000
  # The fixed pages change only with a release, so the release time is when
  # each last changed.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # XML locations pass through escape/1; lastmod accepts only a DateTime.
  # sobelow_skip ["XSS.SendResp"]
  def index(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, document(entries()))
  end

  defp entries do
    sites = Forum.list_directory!(page: [limit: 200]).results
    tools = Forum.list_tools_for_sitemap!() |> Enum.uniq_by(&{&1.site_id, &1.name})
    threads = Forum.list_recent_reports!(load: [:site], page: [limit: @threads]).results

    Enum.map(static(), &{&1, @released_at}) ++
      Enum.map(sites, &{site_path(&1), &1.updated_at}) ++
      Enum.map(tools, &{PatchbayWeb.Forum.BoardHTML.tool_path(&1.site, &1.name), &1.last_seen_at}) ++
      Enum.map(threads, &{"/posts/" <> &1.id, &1.last_activity_at})
  end

  # The motion lab is listed only while the showcase is public.
  defp static do
    pages =
      @static ++
        Enum.map(Troubleshooting.harnesses(), &Troubleshooting.path/1) ++
        Enum.map(Incidents.all(), &("/incidents/" <> &1.name))

    if PatchbayWeb.Showcase.public?(), do: pages ++ ["/animations"], else: pages
  end

  defp site_path(site), do: PatchbayWeb.Forum.BoardHTML.site_path(site)

  defp document(entries) do
    base = PatchbayWeb.Endpoint.url()

    urls =
      Enum.map_join(entries, "\n", fn {path, changed} ->
        "  <url><loc>#{escape(base <> path)}</loc>#{lastmod(changed)}</url>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) <>
      urls <> "\n</urlset>\n"
  end

  defp lastmod(%DateTime{} = at), do: "<lastmod>#{DateTime.to_iso8601(at)}</lastmod>"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
