defmodule PatchbayWeb.SitemapController do
  @moduledoc """
  Every indexable page with the time it last changed: the fixed pages (with the
  troubleshooting pages, each incident's page, and the motion lab while the
  showcase is public), the blog and each article, the Agent Wallet Bench and
  each agent and wallet pair it has run, each site, each tool, and the
  published threads. Bounded, so a crawler never waits on the whole board at
  once.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Incidents
  alias Patchbay.WalletBench
  alias PatchbayWeb.Blog
  alias PatchbayWeb.Forum.Troubleshooting

  @static ~w(/ /sites /questions /priority /start /dots /muse /grokbot /hermes /claude /agent-setup /help /webmcp /docs /about /contact /privacy /terms /changelog /offers /offers/how-it-works /test-me /jev /wallet-bench/how-it-works /incidents)
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
      blog() ++
      wallet_bench() ++
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

  # The blog changes when its newest article is published.
  defp blog do
    posts = Enum.map(Blog.all(), &{"/blog/" <> &1.slug, published_at(&1.date)})
    [{"/blog", newest(posts)} | posts]
  end

  defp published_at(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # Each pair the bench has run, as of its newest run; the board, as of the
  # newest run of all.
  defp wallet_bench do
    {:ok, results} =
      WalletBench.list_results(query: [select: [:harness_id, :wallet_id, :finished_at]])

    pairs =
      results
      |> Enum.group_by(&{&1.harness_id, &1.wallet_id}, & &1.finished_at)
      |> Enum.map(fn {{harness_id, wallet_id}, finished} ->
        {"/wallet-bench/#{harness_id}/#{wallet_id}", Enum.max(finished, DateTime)}
      end)
      |> Enum.sort()

    [{"/wallet-bench", newest(pairs)} | pairs]
  end

  # A listing with nothing in it yet last changed with the release.
  defp newest(entries),
    do: entries |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime, fn -> @released_at end)

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
