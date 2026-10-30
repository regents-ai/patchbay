defmodule PatchbayWeb.Forum.Discussions do
  @moduledoc "Read-only discussion workbench over existing reports; no second thread store."

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.FeedCount
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Report
  alias PatchbayWeb.Endpoint

  @salt "discussion-pages-v1"
  # Ten rows a page keeps the home page short on a phone; older posts are a
  # link away.
  @page_size 10
  @scopes ~w(newest unanswered solved following)
  @loads [
    :author,
    :person,
    :reply_count,
    :solved,
    :view_count,
    :post_like_count,
    :bounty_open,
    :verified_paid_usdc_atomic,
    :post_kind,
    :site
  ]

  @doc """
  The filters a question list is read with. `site` narrows the list to one
  site, named exactly by the domain Patchbay files it under; any other value
  is refused as `{:error, :unknown_site}`. Whether Patchbay has a record of
  that site is read with the list itself (`page/3`).
  """
  @spec filters(map()) :: {:ok, map()} | {:error, :unknown_site}
  def filters(params) do
    with {:ok, site} <- site(params["site"]) do
      {:ok,
       %{
         q: text(params["q"], 200),
         site: site,
         tool: text(params["tool"], 64),
         tag: text(params["tag"], 64),
         scope: if(params["scope"] in @scopes, do: params["scope"], else: "newest"),
         sort: if(params["sort"] == "popular", do: "popular", else: "recent"),
         # The page has no time, package or version filter; the search
         # endpoint reads the same feed with them.
         since: nil,
         package: nil,
         version: nil
       }}
    end
  end

  defp site(absent) when absent in [nil, ""], do: {:ok, ""}

  defp site(domain) when is_binary(domain) do
    case Origin.normalize(domain) do
      {:ok, ^domain} -> {:ok, domain}
      _not_a_domain -> {:error, :unknown_site}
    end
  end

  defp site(_not_text), do: {:error, :unknown_site}

  @doc """
  The same follow list with what each subscription follows: the site, the
  tool with its site, or the thread. A follow whose target is gone is left out.
  """
  def following(principals) do
    subscriptions =
      Forum.list_subscriptions_for_principals!(principals, actor: %{principals: principals})

    targets = %{
      site: by_id(Patchbay.Forum.Site, ids(subscriptions, :site)),
      tool: by_id(Patchbay.Forum.Tool, ids(subscriptions, :tool), load: [:site]),
      thread: by_id(Report, ids(subscriptions, :thread), load: [:site, :tool])
    }

    for subscription <- subscriptions,
        target = targets[subscription.scope_kind][subscription.scope_id],
        do: {subscription, target}
  end

  defp ids(subscriptions, kind),
    do: for(%{scope_kind: ^kind, scope_id: id} <- subscriptions, do: id)

  defp by_id(_resource, [], _opts), do: %{}

  defp by_id(resource, ids, opts) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(opts)
    |> Map.new(&{&1.id, &1})
  end

  defp by_id(resource, ids), do: by_id(resource, ids, [])

  @doc """
  One page of the question list. A list narrowed to a site Patchbay has no
  record of is `{:error, :unknown_site}`; a list that could not be read is
  the read's own error.
  """
  def page(filters, subscriptions, token) do
    context = {filters, FeedCount.followed(filters, subscriptions)}

    with :ok <- on_record(filters.site),
         {:ok, keyset} <- verify(token, context),
         {:ok, page} <-
           Forum.list_feed_reports(
             query: Patchbay.Forum.Feed.query(filters, subscriptions),
             page: if(keyset, do: [limit: @page_size, after: keyset], else: [limit: @page_size])
           ),
         {:ok, page} <- Ash.load(page, @loads) do
      {:ok, page.results, continuation(page, context)}
    end
  end

  @doc """
  How many threads a question list holds, across all its pages, kept a minute
  (`Patchbay.Forum.FeedCount`). The Following list counts the follows it is
  given.
  """
  @spec count(map(), list()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(filters, subscriptions \\ []), do: FeedCount.count(filters, subscriptions)

  defp on_record(""), do: :ok

  defp on_record(domain) do
    case Forum.get_site_by_origin(domain, not_found_error?: false) do
      {:ok, nil} -> {:error, :unknown_site}
      {:ok, _site} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  defp continuation(%{more?: true, results: results}, context) do
    Phoenix.Token.sign(Endpoint, @salt, {context, List.last(results).__metadata__.keyset})
  end

  defp continuation(_page, _context), do: nil

  defp verify(nil, _context), do: {:ok, nil}

  defp verify(token, context) when is_binary(token) and byte_size(token) <= 8192 do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: 86_400) do
      {:ok, {^context, keyset}} when is_binary(keyset) -> {:ok, keyset}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp verify(_token, _context), do: {:error, :invalid_cursor}

  defp text(value, limit) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, limit)

  defp text(_value, _limit), do: ""
end
