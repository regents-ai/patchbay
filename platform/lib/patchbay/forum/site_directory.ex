defmodule Patchbay.Forum.SiteDirectory do
  @moduledoc """
  Public website listings, with what Patchbay's own site checks found: the
  saved listing's sites, then every board outside it with a tool a check found
  or a public post, busiest first, searched and paged together.

  The listing names each site's page and the other pages it lists, such as
  `web.autocad.com` or a `chatgpt.site` app. A site's check reads them all
  (`pages/1`), at most `most_pages/0` of them besides its front page. The
  row for the site itself shows the count its board shows
  (`Patchbay.Forum.SiteCheck.tools/1`); a row for another address on it, such
  as a product's own, counts only that row's pages (`SiteCheck.tools/2`), so
  one maker's count is never another's. A row Patchbay has not checked has
  no count.
  """

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.{HiddenSites, ListedSitePicture, Origin, Site, SiteCheck}

  @external_resource "priv/data/site_directory.json"
  @document Jason.decode!(File.read!(@external_resource))
  @external_resource "priv/data/webmcp_sites.json"
  @logos Jason.decode!(File.read!("priv/data/webmcp_sites.json"))["entries"]
         |> Map.new(&{&1["origin"], &1["logo_path"]})
  @entries for entry <- @document["sites"],
               {:ok, domain} <- [Origin.normalize(entry["host"])],
               do: Map.put(entry, "domain", domain)
  @by_domain Enum.group_by(@entries, & &1["domain"])
  @domains @entries |> Enum.map(& &1["domain"]) |> Enum.uniq()
  @page_size 30
  @most_pages 20

  @doc "Every listed domain, once, in listing order."
  def domains, do: @domains

  def categories, do: @entries |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort()

  @doc "How many listed pages one site's check reads at most, besides its front page."
  @spec most_pages() :: pos_integer()
  def most_pages, do: @most_pages

  @doc """
  The exact public pages to inspect for a domain: every listed row's own page
  and the other pages it lists, in listing order, at most `most_pages/0`.
  """
  def pages(domain) do
    @by_domain
    |> Map.get(domain, [])
    |> Enum.flat_map(&entry_pages/1)
    |> Enum.uniq()
    |> Enum.take(@most_pages)
  end

  @doc "One page of the listing with its checks and forum counts, or why `params` names no page."
  @spec page(map()) :: {:ok, map()} | {:error, {:invalid, [String.t()]}}
  def page(params) do
    with {:ok, number} <- page_number(params["page"]),
         do: {:ok, params |> select(number, HiddenSites.reading().hosts) |> read()}
  end

  @doc """
  Reads the listed hosts whose last finished check read every one of their
  pages and found no WebMCP tool, there or on the site's front page. Every
  listing leaves them out, and its totals do not count them, until a check
  finds a tool; their own pages stay open. Listings take them from
  `Patchbay.Forum.HiddenSites`, which calls this.
  """
  @spec read_hidden_hosts() :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def read_hidden_hosts do
    with {:ok, checks} <- Forum.list_site_checks_without_tools() do
      hosts =
        for check <- checks,
            seed <- Map.get(@by_domain, check.domain, []),
            Enum.all?(entry_pages(seed), &(&1 in check.read_directory_pages)),
            into: MapSet.new(),
            do: seed["host"]

      {:ok, hosts}
    end
  end

  @doc "The domains every listed host of which is among `hosts`."
  @spec hidden_domains(MapSet.t(String.t())) :: [String.t()]
  def hidden_domains(hosts) do
    for {domain, seeds} <- @by_domain,
        Enum.all?(seeds, &MapSet.member?(hosts, &1["host"])),
        do: domain
  end

  defp read(selected) do
    domains = selected.sites |> Enum.map(&domain/1) |> Enum.uniq()
    checks = SiteCheck |> Ash.Query.filter(domain in ^domains) |> Ash.read!()
    page = decorate(selected, Map.new(checks, &{&1.domain, &1}))

    # One public aggregate read for the visible domains. Hidden posts never count.
    result =
      with {:ok, sites} <-
             Site
             |> Ash.Query.filter(origin in ^domains)
             |> Ash.Query.select([:origin, :logo_path, :screenshot_path])
             |> Ash.Query.load(:report_count)
             |> Ash.read(),
           {:ok, pictures} <- Forum.list_shown_listed_site_pictures(domains),
           do: {:ok, sites, pictures}

    with_forum(page, result)
  end

  defp with_forum(page, {:error, _failure}), do: page

  defp with_forum(page, {:ok, sites, pictures}) do
    sites = Map.new(sites, &{&1.origin, &1})
    pictures = Map.new(pictures, &{&1.domain, ListedSitePicture.path(&1)})

    Map.update!(page, :sites, fn entries ->
      Enum.map(entries, &attach_forum(&1, Map.get(sites, &1.domain), pictures))
    end)
  end

  # A site with no board shows the picture Patchbay took of its home page for
  # the list (`Patchbay.Forum.ListedSitePictureSweep`).
  defp attach_forum(entry, nil, pictures),
    do: %{entry | forum_posts: 0, screenshot_path: Map.get(pictures, entry.domain)}

  # The picture is the one Patchbay took of the site's home page, kept and
  # served by Patchbay itself (`Patchbay.Forum.TakeSitePicture`).
  defp attach_forum(entry, site, _pictures) do
    %{
      entry
      | forum_posts: site.report_count,
        logo_path: site.logo_path || entry.logo_path,
        screenshot_path: site.screenshot_path
    }
  end

  # Filter the saved public listing, leaving out the hidden hosts, and page it
  # with the boards outside it that match: the listing's sites, then the boards.
  defp select(params, number, hidden) do
    q = text(params["q"], 100)
    category = text(params["category"], 80)
    words = q |> String.downcase() |> String.split()

    entries =
      Enum.filter(@entries, fn entry ->
        haystack = String.downcase(entry["name"] <> " " <> entry["host"])

        not MapSet.member?(hidden, entry["host"]) and
          (category == "" or entry["category"] == category) and
          Enum.all?(words, &String.contains?(haystack, &1))
      end)

    boards = board_count(words, category)
    total = length(entries) + boards
    pages = max(1, ceil(total / @page_size))
    page = min(number, pages)
    start = (page - 1) * @page_size
    listed = Enum.slice(entries, start, @page_size)
    offset = max(start - length(entries), 0)
    room = min(@page_size - length(listed), boards - offset)

    %{
      sites:
        Enum.map(listed, &{:seed, &1}) ++
          Enum.map(boards(words, offset, room), &{:board, &1}),
      total: total,
      page: page,
      pages: pages,
      q: q,
      category: category
    }
  end

  # A board carries no category, so a search by category lists none.
  defp board_count(_words, category) when category != "", do: 0

  defp board_count(words, _category) do
    Site
    |> Ash.Query.for_read(:directory_boards, %{except: @domains, words: words})
    |> Ash.count!()
  end

  defp boards(_words, _offset, room) when room <= 0, do: []

  defp boards(words, offset, room),
    do: Forum.list_directory_boards!(@domains, words, page: [offset: offset, limit: room]).results

  defp decorate(page, checks),
    do: Map.put(page, :sites, Enum.map(page.sites, &entry(&1, Map.get(checks, domain(&1)))))

  def replace_check(page, check) do
    Map.put(page, :sites, Enum.map(page.sites, &replace_entry(&1, check)))
  end

  defp replace_entry(%{domain: domain} = site, %{domain: domain} = check),
    do:
      Map.merge(
        entry(site.listing, check),
        Map.take(site, [:forum_posts, :logo_path, :screenshot_path])
      )

  defp replace_entry(site, _check), do: site

  # The listing's own words for a site, with the tools Patchbay's check found:
  # the row whose host is the site itself shows the count the site's board
  # shows, and a row for another address on it counts that row's pages.
  defp entry({:seed, seed} = listing, check) do
    domain = domain(listing)

    tools =
      if seed["host"] in [domain, "www." <> domain],
        do: SiteCheck.tools(check),
        else: SiteCheck.tools(check, entry_pages(seed))

    %{
      listing: listing,
      host: seed["host"],
      domain: domain,
      name: seed["name"],
      category: seed["category"],
      page_url: seed["url"],
      logo_path: Map.get(@logos, domain)
    }
    |> Map.merge(found(tools, check))
  end

  # A board's row: the tools Patchbay's check found on the site, as its own
  # page counts them.
  defp entry({:board, site} = listing, check) do
    %{
      listing: listing,
      host: site.origin,
      domain: site.origin,
      name: site.display_name || site.origin,
      category: nil,
      page_url: "https://" <> site.origin <> "/",
      logo_path: nil
    }
    |> Map.merge(found(SiteCheck.tools(check), check))
  end

  # A row's count is nil, not a number, until a check of the site finishes.
  defp found(tools, check) do
    %{
      tools: tools || [],
      tool_count: tools && length(tools),
      forum_posts: nil,
      screenshot_path: nil,
      checked_at: checked_at(check),
      pending?: pending?(check),
      due?: SiteCheck.due?(check),
      retry_at: retry_at(check)
    }
  end

  defp checked_at(%{checked_at: %DateTime{} = at, findings: %{} = findings}),
    do: if(findings["failed"] == true, do: nil, else: DateTime.to_iso8601(at))

  defp checked_at(_check), do: nil

  defp entry_pages(seed), do: Enum.uniq([seed["url"] | seed["pages"]])

  defp pending?(nil), do: false
  defp pending?(check), do: SiteCheck.pending?(check)

  defp retry_at(%{checked_at: %DateTime{} = checked_at}),
    do: DateTime.add(checked_at, 86_400)

  defp retry_at(_check), do: nil

  def page_url(page, number) do
    "/sites?" <> URI.encode_query(%{"q" => page.q, "category" => page.category, "page" => number})
  end

  defp domain({:seed, seed}), do: Map.fetch!(seed, "domain")
  defp domain({:board, site}), do: site.origin

  defp text(value, limit) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, limit)

  defp text(_value, _limit), do: ""

  @doc "The page an address asks for: 1 when it names none, refused unless a whole number from 1."
  @spec page_number(term()) :: {:ok, pos_integer()} | {:error, {:invalid, [String.t()]}}
  def page_number(nil), do: {:ok, 1}

  def page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page >= 1 -> {:ok, page}
      _other -> page_refused()
    end
  end

  def page_number(_value), do: page_refused()

  defp page_refused, do: {:error, {:invalid, ["page: must be a whole number from 1."]}}
end
