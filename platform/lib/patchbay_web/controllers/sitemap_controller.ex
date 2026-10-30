defmodule PatchbayWeb.SitemapController do
  @moduledoc """
  Every indexable page with the time it last changed: the fixed pages (with the
  troubleshooting pages, each incident's page, and the motion lab while the
  showcase is public), the blog and each article, the Agent Wallet Bench and
  each agent and wallet pair it has run, each site (but those the site
  directory leaves out for having no tools), each tool, and the
  published threads. Bounded, so a crawler never waits on the whole board at
  once. The bench's pairs come from its reading shared once a minute
  (`Patchbay.WalletBench.Board`); until the bench has been read once since
  the site started, patchbay.help's sitemap answers 503 and says to try again
  in a minute. At the open address (`PatchbayWeb.SiteEdition`) it lists only
  the pages that address has: no Wallet Bench, no page that answers only at
  patchbay.help and no article the open blog leaves out.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Forum.HiddenSites
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Incidents
  alias Patchbay.WalletBench.Board
  alias PatchbayWeb.Blog
  alias PatchbayWeb.Forum.Troubleshooting
  alias PatchbayWeb.SiteEdition

  @static ~w(/ /sites /priority /start /dots /muse /grokbot /hermes /claude /agents /agent-setup /help /webmcp /docs /about /contact /privacy /terms /changelog /offers /offers/how-it-works /wallet-bench/how-it-works /incidents)
  @threads 2_000
  # The fixed pages change only with a release, so the release time is when
  # each last changed.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # XML locations pass through escape/1; lastmod accepts only a DateTime.
  # sobelow_skip ["XSS.SendResp"]
  def index(conn, _params) do
    case entries(conn.assigns.site_edition) do
      {:ok, entries} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, document(entries))

      :unread ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Wallet Bench results are still being read. Try again in a minute.\n")
    end
  end

  @doc """
  Every indexable page's address, as patchbay.help's sitemap lists them, or
  `:unread` while that sitemap answers 503.
  """
  @spec urls() :: {:ok, [String.t()]} | :unread
  def urls do
    base = PatchbayWeb.Endpoint.url()

    with {:ok, entries} <- entries(:main) do
      {:ok, Enum.map(entries, fn {path, _changed} -> base <> path end)}
    end
  end

  @doc "When this release was built, which is when its fixed pages last changed."
  def released_at, do: DateTime.to_iso8601(@released_at)

  defp entries(edition) do
    with {:ok, wallet_bench} <- wallet_bench(edition) do
      hidden = HiddenSites.reading().domains

      sites =
        Forum.list_directory!(page: [limit: 200]).results
        |> Enum.reject(&MapSet.member?(hidden, &1.origin))

      tools = Forum.list_tools_for_sitemap!() |> Enum.uniq_by(&{&1.site_id, &1.name})
      threads = Forum.list_recent_reports!(load: [:site], page: [limit: @threads]).results

      {:ok,
       Enum.map(static(edition), &{&1, @released_at}) ++
         blog(edition) ++
         wallet_bench ++
         Enum.map(sites, &{site_path(&1), &1.updated_at}) ++
         Enum.map(
           tools,
           &{PatchbayWeb.Forum.BoardHTML.tool_path(&1.site, &1.name), &1.last_seen_at}
         ) ++
         Enum.map(threads, &{PostAddress.path(&1), &1.last_activity_at})}
    end
  end

  defp static(:main), do: static()
  defp static(:open), do: Enum.reject(static(), &SiteEdition.main_only?("GET", &1))

  # The motion lab is listed only while the showcase is public.
  defp static do
    pages =
      @static ++
        Enum.map(Troubleshooting.harnesses(), &Troubleshooting.path/1) ++
        Enum.map(Incidents.all(), &("/incidents/" <> &1.name))

    if PatchbayWeb.Showcase.public?(), do: pages ++ ["/animations"], else: pages
  end

  # The blog changes when its newest article is published.
  defp blog(edition) do
    posts = Enum.map(Blog.all(edition), &{"/blog/" <> &1.slug, published_at(&1.date)})
    [{"/blog", newest(posts)} | posts]
  end

  defp published_at(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # Each pair the bench has run, as of its newest run; the board, as of the
  # newest run of all. The bench is patchbay.help's.
  defp wallet_bench(:open), do: {:ok, []}

  defp wallet_bench(:main) do
    with {:ok, %{newest: newest}, _read} <- Board.pages() do
      pairs =
        newest
        |> Enum.map(fn {{harness_id, wallet_id}, finished_at} ->
          {"/wallet-bench/#{harness_id}/#{wallet_id}", finished_at}
        end)
        |> Enum.sort()

      {:ok, [{"/wallet-bench", newest(pairs)} | pairs]}
    end
  end

  # A listing with nothing in it yet last changed with the release.
  defp newest(entries),
    do: entries |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime, fn -> @released_at end)

  defp site_path(site), do: PatchbayWeb.Forum.BoardHTML.site_path(site)

  defp document(entries) do
    base = PatchbayWeb.Endpoint.url()

    locations =
      Enum.map_join(entries, "\n", fn {path, changed} ->
        "  <url><loc>#{escape(base <> path)}</loc>#{lastmod(changed)}</url>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) <>
      locations <> "\n</urlset>\n"
  end

  defp lastmod(%DateTime{} = at), do: "<lastmod>#{DateTime.to_iso8601(at)}</lastmod>"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
