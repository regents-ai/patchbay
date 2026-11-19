defmodule Patchbay.Changelog do
  @moduledoc "The repository changelog, embedded in the release with newest entries first."

  @path Path.expand("../../../CHANGELOG.md", __DIR__)
  @external_resource @path
  @open_marker "<!-- open -->"
  @document @path
            |> File.read!()
            |> MDEx.parse_document!(extension: [inline_code_attributes: false])
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
         |> Enum.map(fn [heading | body] ->
           title = MDEx.to_markdown!(%{@document | nodes: [heading]}) |> String.trim()

           [date] =
             Regex.run(~r/\A## (\d{4}-\d{2}-\d{2}) — .+\z/u, title, capture: :all_but_first)

           {markers, body} =
             Enum.split_with(body, fn
               %MDEx.HtmlBlock{literal: text} -> String.trim(text) == @open_marker
               _other -> false
             end)

           {Date.from_iso8601!(date), [heading | body], markers != []}
         end)
         |> Enum.sort_by(&elem(&1, 0), {:desc, Date})
  @dates Enum.map(@dated, &elem(&1, 0))

  @per_page 12
  @entries @dated
           |> Enum.with_index()
           |> Enum.map(fn {{_date, nodes, open?}, index} ->
             %{
               id: length(@dated) - index,
               nodes: nodes,
               html: Patchbay.AddressText.html(%{@document | nodes: nodes}),
               open?: open?
             }
           end)
  @editions Map.new([:main, :open], fn edition ->
              entries = if edition == :open, do: Enum.filter(@entries, & &1.open?), else: @entries

              intro =
                if edition == :open,
                  do: Enum.filter(@intro, &match?(%MDEx.Heading{level: 1}, &1)),
                  else: @intro

              nodes = intro ++ Enum.flat_map(entries, & &1.nodes)

              {edition,
               %{
                 pages:
                   entries |> Enum.map(&Map.take(&1, [:id, :html])) |> Enum.chunk_every(@per_page),
                 intro:
                   Patchbay.AddressText.html(%{
                     @document
                     | nodes: Enum.reject(intro, &match?(%MDEx.Heading{level: 1}, &1))
                   }),
                 markdown: MDEx.to_markdown!(%{@document | nodes: nodes})
               }}
            end)

  @doc """
  One page of the dated entries, newest first, and the number of pages for
  that edition. Open carries only entries marked `<!-- open -->` in the source.
  Each entry keeps the same anchor on both addresses.
  """
  @spec page(pos_integer(), :main | :open) :: {:ok, [map()], pos_integer()} | :error
  def page(number, edition) when number > 0 do
    pages = @editions[edition].pages

    case Enum.fetch(pages, number - 1) do
      {:ok, entries} -> {:ok, entries, length(pages)}
      :error -> :error
    end
  end

  @doc "The words before the first entry, as the entries' pieces (`Patchbay.AddressText.html/1`)."
  def intro(edition), do: @editions[edition].intro
  def markdown(edition), do: @editions[edition].markdown

  @doc "How many entries are dated after the given day."
  @spec entries_after(Date.t()) :: non_neg_integer()
  def entries_after(%Date{} = day), do: Enum.count(@dates, &(Date.compare(&1, day) == :gt))
end
