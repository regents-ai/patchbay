defmodule Patchbay.Forum.SiteDirectory do
  @moduledoc "Public website listings, with 24-hour observations from the existing site-check jobs."

  require Ash.Query

  alias Patchbay.Forum.{Origin, SiteCheck}

  @external_resource "priv/data/site_directory.json"
  @document Jason.decode!(File.read!(@external_resource))
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

  def page(params) do
    selected = select(params)
    domains = selected.sites |> Enum.map(&domain/1) |> Enum.uniq()

    case SiteCheck |> Ash.Query.filter(domain in ^domains) |> Ash.read() do
      {:ok, checks} -> decorate(selected, Map.new(checks, &{&1.domain, &1}), true)
      {:error, _failure} -> decorate(selected, %{}, false)
    end
  end

  @doc "Filter and paginate the saved public listing without a database read."
  def select(params) do
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
    page = min(number(params["page"]), pages)

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
    do: entry(site.seed, check)

  defp replace_entry(site, _check), do: site

  def entry(seed, check) do
    snapshot = snapshot(seed, (check && check.findings) || %{})
    observed = snapshot && snapshot["tools"]

    %{
      seed: seed,
      host: seed["host"],
      domain: domain(seed),
      name: seed["name"],
      category: seed["category"],
      page_url: seed["url"],
      tools: observed || seed["tools"],
      checked_at: snapshot && snapshot["checked_at"],
      failed?: failed?(snapshot, check),
      pending?: pending?(check),
      due?: SiteCheck.due?(check, :directory),
      retry_at: retry_at(check),
      source: if(observed, do: "Source scan", else: "Research listing")
    }
  end

  defp entry_pages(seed), do: Enum.uniq([seed["url"] | Enum.map(seed["tools"], & &1["address"])])

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

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  defp number(_value), do: 1
end
