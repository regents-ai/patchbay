defmodule Patchbay.Changelog do
  @moduledoc "The repository changelog, embedded in the release with newest entries first."

  @path Path.expand("../../../CHANGELOG.md", __DIR__)
  @external_resource @path
  @document @path |> File.read!() |> MDEx.parse_document!()
  @intro Enum.take_while(@document.nodes, &(!match?(%MDEx.Heading{level: 2}, &1)))
  @dated @document.nodes
         |> Enum.drop(length(@intro))
         |> Enum.chunk_while(
           [],
           fn
             %MDEx.Heading{level: 2} = node, [] -> {:cont, [node]}
             %MDEx.Heading{level: 2} = node, acc -> {:cont, Enum.reverse(acc), [node]}
             node, acc -> {:cont, [node | acc]}
           end,
           fn
             [] -> {:cont, []}
             acc -> {:cont, Enum.reverse(acc), []}
           end
         )
         |> Enum.map(fn [heading | _] = nodes ->
           title = MDEx.to_markdown!(%{@document | nodes: [heading]}) |> String.trim()

           [date] =
             Regex.run(~r/\A## (\d{4}-\d{2}-\d{2}) — .+\z/u, title, capture: :all_but_first)

           {Date.from_iso8601!(date), nodes}
         end)
         |> Enum.sort_by(&elem(&1, 0), {:desc, Date})
  @releases Enum.map(@dated, &elem(&1, 1))
  @dates Enum.map(@dated, &elem(&1, 0))

  @entries Enum.map(@releases, fn nodes ->
             Patchbay.AddressText.html(%{@document | nodes: nodes})
           end)
  @intro_html MDEx.to_html!(
                %{@document | nodes: Enum.reject(@intro, &match?(%MDEx.Heading{level: 1}, &1))},
                render: [unsafe: false]
              )
  @markdown MDEx.to_markdown!(%{@document | nodes: @intro ++ List.flatten(@releases)})

  # The page shows twelve entries at a time; the Markdown answer stays whole.
  @per_page 12
  @pages Enum.chunk_every(@entries, @per_page)
  @page_count length(@pages)

  @doc """
  One page of the dated entries as HTML, newest first, with their addresses cut
  out (`Patchbay.AddressText.html/1`): the entries, how many entries come
  before them, and how many pages there are. The first page is the newest.
  """
  @spec page(integer()) :: {:ok, [term()], non_neg_integer(), pos_integer()} | :error
  def page(number) when number in 1..@page_count//1,
    do: {:ok, Enum.at(@pages, number - 1), (number - 1) * @per_page, @page_count}

  def page(_number), do: :error

  def intro_html, do: @intro_html
  def markdown, do: @markdown

  @doc "How many entries are dated after the given day."
  @spec entries_after(Date.t()) :: non_neg_integer()
  def entries_after(%Date{} = day), do: Enum.count(@dates, &(Date.compare(&1, day) == :gt))
end
