defmodule PatchbayWeb.Forum.Discussions do
  @moduledoc "Read-only discussion workbench over existing reports; no second thread store."

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias PatchbayWeb.Endpoint

  @salt "discussion-pages-v1"
  @scopes ~w(all unanswered priority following)
  @loads [:reply_count, :post_kind, tool: [:site]]

  def filters(params) do
    %{
      q: text(params["q"], 200),
      site: text(params["site"], 255),
      scope: if(params["scope"] in @scopes, do: params["scope"], else: "all")
    }
  end

  def following(value) when is_binary(value) and byte_size(value) <= 4096 do
    value
    |> String.split(",", trim: true)
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
    |> Enum.take(80)
  end

  def following(_), do: []

  def page(filters, following, token) do
    context = {filters, if(filters.scope == "following", do: Enum.sort(following), else: [])}

    with {:ok, keyset} <- verify(token, context),
         {:ok, page} <-
           Forum.list_recent_reports(
             query: query(filters, following),
             load: @loads,
             page: if(keyset, do: [limit: 20, after: keyset], else: [limit: 20])
           ) do
      {:ok, page.results, continuation(page, context)}
    end
  end

  # Search the report text as well as its site/tool. Filtering happens before
  # keyset pagination, not against an arbitrary handful of tool versions.
  defp query(filters, following) do
    Report
    |> search(filters.q)
    |> site(filters.site)
    |> scope(filters.scope, following)
  end

  defp search(query, ""), do: query

  defp search(query, term) do
    Ash.Query.filter(
      query,
      contains(string_downcase(note), string_downcase(^term)) or
        contains(string_downcase(tool.name), string_downcase(^term)) or
        contains(string_downcase(tool.site.origin), string_downcase(^term)) or
        contains(string_downcase(tool.site.display_name), string_downcase(^term))
    )
  end

  defp site(query, ""), do: query
  defp site(query, ref), do: Ash.Query.filter(query, tool.site.origin == ^ref)

  defp scope(query, "unanswered", _following), do: Ash.Query.filter(query, reply_count == 0)

  # Recorded paid placement is not proof that an answer is correct. Do not
  # include pending payment intents or refunded reports in this scope.
  defp scope(query, "priority", _following) do
    Ash.Query.filter(query, verified_paid_usdc_atomic > 0)
  end

  defp scope(query, "following", following),
    do: Ash.Query.filter(query, tool.site_id in ^following)

  defp scope(query, _scope, _following), do: query

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
