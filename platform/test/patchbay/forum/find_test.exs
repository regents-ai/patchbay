defmodule Patchbay.Forum.FindTest do
  @moduledoc """
  The site and tool matches beside the front page's search (`:find`,
  `Patchbay.Forum.FindText`) read an index for every condition, never every
  row of a table, and find the typed words anywhere in an address, name or
  title, in any case, `%` and `_` taken as themselves.
  """

  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Forum.{Site, Tool}

  test "each match reads its own indexes" do
    for {resource, indexes} <- [
          {Site, ~w(forum_sites_origin_trgm_index forum_sites_display_name_trgm_index)},
          {Tool, ~w(forum_tools_name_trgm_index forum_tools_title_trgm_index)}
        ] do
      {:ok, query} =
        resource
        |> Ash.Query.for_read(:find, %{text: "basket"})
        |> Ash.Query.data_layer_query()

      {sql, params} = Repo.to_sql(:all, query)

      # With every way to read a table but a bitmap of index matches turned
      # off, PostgreSQL plans with an index wherever one answers a condition,
      # however few rows the tables hold; a condition no index can answer
      # names none.
      Repo.transaction(fn ->
        for scan <- ~w(seqscan indexscan indexonlyscan),
            do: Repo.query!("SET LOCAL enable_#{scan} = off")

        plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

        for index <- indexes, do: assert(plan =~ index, "#{index} not read:\n#{plan}")
      end)
    end
  end

  test "finds a site by any part of its address, in any case" do
    n = System.unique_integer([:positive])
    site = Forum.register_site!("kettlebell#{n}.example")

    assert [%{id: id}] = Forum.find_sites!("BELL#{n}.EXA")
    assert id == site.id
  end

  test "finds a tool by any part of its name or title, in any case" do
    n = System.unique_integer([:positive])
    site = Forum.register_site!("tools#{n}.example")
    tool!(site, "empty_basket#{n}", "Clear the trolley")

    assert names("BASKET#{n}") == ["empty_basket#{n}"]
    assert names("the TROLLEY") == ["empty_basket#{n}"]
  end

  test "takes % and _ as themselves" do
    n = System.unique_integer([:positive])
    site = Forum.register_site!("literal#{n}.example")
    tool!(site, "empty_basket#{n}", nil)
    tool!(site, "emptyxbasket#{n}", nil)

    assert names("y_b") |> Enum.filter(&String.ends_with?(&1, "#{n}")) == ["empty_basket#{n}"]
    assert Forum.find_sites!("%%") == []
    assert Forum.find_tools!("%%") == []
  end

  defp tool!(site, name, title) do
    Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
      name: name,
      title: title,
      contract_sha256: :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    })
  end

  defp names(text), do: text |> Forum.find_tools!() |> Enum.map(& &1.name)
end
