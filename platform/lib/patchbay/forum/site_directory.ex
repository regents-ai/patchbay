defmodule Patchbay.Forum.SiteDirectory do
  @moduledoc "Public website listings, with 24-hour observations from the existing site-check jobs."

  require Ash.Query

  alias Patchbay.Forum.{Origin, Site, SiteCheck}

  @external_resource "priv/data/site_directory.json"
  @document Jason.decode!(File.read!(@external_resource))
  @external_resource "priv/data/webmcp_sites.json"
  @logos Jason.decode!(File.read!("priv/data/webmcp_sites.json"))["entries"]
         |> Map.new(&{&1["origin"], &1["logo_path"]})
  @entries for entry <- @document["sites"],
               {:ok, domain} <- [Origin.normalize(entry["host"])],
               do: Map.put(entry, "domain", domain)
  @by_domain Enum.group_by(@entries, & &1["domain"])
  @page_size 30

  def categories, do: @entries |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort()

  @doc "The exact public pages to inspect for a domain, including its listed subdomains."
  def pages(domain) do
    @by_domain
    |> Map.get(domain, [])
    |> Enum.flat_map(&entry_pages/1)
    |> Enum.uniq()
  end

  @doc "One page of the listing with its checks and forum counts, or why `params` names no page."
  @spec page(map()) :: {:ok, map()} | {:error, {:invalid, [String.t()]}}
  def page(params) do
    with {:ok, selected} <- select(params), do: {:ok, read(selected)}
  end

  defp read(selected) do
    domains = selected.sites |> Enum.map(&domain/1) |> Enum.uniq()

    page =
      case SiteCheck |> Ash.Query.filter(domain in ^domains) |> Ash.read() do
        {:ok, checks} -> decorate(selected, Map.new(checks, &{&1.domain, &1}), true)
        {:error, _failure} -> decorate(selected, %{}, false)
      end

    # One public aggregate read for the visible domains. Hidden posts never count.
    result =
      Site
      |> Ash.Query.filter(origin in ^domains)
      |> Ash.Query.select([:origin, :logo_path])
      |> Ash.Query.load(:report_count)
      |> Ash.read()

    with_forum(page, result)
  end

  def with_forum(page, {:error, _failure}), do: page

  def with_forum(page, {:ok, sites}) do
    sites = Map.new(sites, &{&1.origin, &1})

    Map.update!(page, :sites, fn entries ->
      Enum.map(entries, &attach_forum(&1, Map.get(sites, &1.domain)))
    end)
  end

  defp attach_forum(entry, nil), do: %{entry | forum_posts: 0}

  defp attach_forum(entry, site),
    do: %{entry | forum_posts: site.report_count, logo_path: site.logo_path || entry.logo_path}

  @doc "Filter and paginate the saved public listing without a database read."
  def select(params) do
    with {:ok, number} <- page_number(params["page"]), do: {:ok, select(params, number)}
  end

  defp select(params, number) do
    q = text(params["q"], 100)
    category = text(params["category"], 80)
    words = q |> String.downcase() |> String.split()

    entries =
      Enum.filter(@entries, fn entry ->
        haystack = String.downcase(entry["name"] <> " " <> entry["host"])

        (category == "" or entry["category"] == category) and
          Enum.all?(words, &String.contains?(haystack, &1))
      end)

    total = length(entries)
    pages = max(1, ceil(total / @page_size))
    page = min(number, pages)

    %{
      sites: Enum.slice(entries, (page - 1) * @page_size, @page_size),
      total: total,
      page: page,
      pages: pages,
      q: q,
      category: category,
      imported_at: @document["imported_at"]
    }
  end

  def decorate(page, checks, available?) do
    page
    |> Map.put(:sites, Enum.map(page.sites, &entry(&1, Map.get(checks, domain(&1)))))
    |> Map.put(:cache_available?, available?)
  end

  def replace_check(page, check) do
    Map.put(page, :sites, Enum.map(page.sites, &replace_entry(&1, check)))
  end

  defp replace_entry(%{domain: domain} = site, %{domain: domain} = check),
    do: Map.merge(entry(site.seed, check), Map.take(site, [:forum_posts, :logo_path]))

  defp replace_entry(site, _check), do: site

  def entry(seed, check) do
    snapshot = snapshot(seed, (check && check.findings) || %{})
    observed = snapshot && snapshot["tools"]
    tools = Enum.uniq_by(observed || seed["tools"], & &1["name"])

    %{
      seed: seed,
      host: seed["host"],
      domain: domain(seed),
      name: seed["name"],
      category: seed["category"],
      page_url: seed["url"],
      tools: tools,
      tool_count: if(observed, do: length(tools), else: reported_count(seed, tools)),
      reported_observation: seed["reported_observation"],
      forum_posts: nil,
      logo_path: Map.get(@logos, domain(seed)),
      checked_at: snapshot && snapshot["checked_at"],
      failed?: failed?(snapshot, check),
      pending?: pending?(check),
      due?: SiteCheck.due?(check, :directory),
      retry_at: retry_at(check),
      source: if(observed, do: "Source scan", else: "Research listing")
    }
  end

  defp reported_count(%{"reported_tool_count" => count}, _tools), do: count
  defp reported_count(_seed, []), do: nil
  defp reported_count(_seed, tools), do: length(tools)

  defp entry_pages(seed),
    do:
      Enum.uniq(
        [seed["url"] | Enum.map(seed["tools"], & &1["address"])] ++
          Map.get(seed, "additional_urls", [])
      )

  defp snapshot(seed, findings) do
    snapshots = Enum.map(entry_pages(seed), &get_in(findings, ["directory", &1]))
    failed? = Enum.any?(snapshots, &match?(%{"failed" => true}, &1))

    if Enum.all?(snapshots, &match?(%{"tools" => tools} when is_list(tools), &1)) do
      %{
        "tools" => snapshots |> Enum.flat_map(& &1["tools"]) |> Enum.uniq(),
        "checked_at" => snapshots |> Enum.map(& &1["checked_at"]) |> Enum.min(),
        "failed" => failed?
      }
    else
      %{"tools" => nil, "checked_at" => nil, "failed" => failed?}
    end
  end

  defp failed?(%{"failed" => true}, _check), do: true
  defp failed?(_snapshot, %{findings: %{"failed" => true}}), do: true
  defp failed?(_snapshot, _check), do: false

  defp pending?(nil), do: false
  defp pending?(check), do: SiteCheck.pending?(check)

  defp retry_at(%{checked_at: %DateTime{} = checked_at}),
    do: DateTime.add(checked_at, 86_400)

  defp retry_at(_check), do: nil

  def page_url(page, number) do
    "/sites?" <> URI.encode_query(%{"q" => page.q, "category" => page.category, "page" => number})
  end

  defp domain(entry) do
    Map.fetch!(entry, "domain")
  end

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
