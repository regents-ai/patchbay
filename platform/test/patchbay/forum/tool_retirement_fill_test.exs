defmodule Patchbay.Forum.ToolRetirementFillTest do
  @moduledoc """
  The one-time fill of the tool retirement columns leaves every site offering
  the tools it offered before. Until then a tool's `current?` was worked out
  from the stored findings of its site's check, and each expected value below
  is that rule's answer for the rows as written:

    * a check read its page whole at its check time when its findings named a
      page, had not failed, were marked `page_complete` and held at least one
      WebMCP tool;
    * on a site with a published list (an official tool), a tool was offered
      when seen at or after the newest official tool;
    * on any other site, a tool was hidden only when the site is outside the
      researched directory, its check read the page whole, and the tool sits
      on that page and was last seen before then.
  """

  use Patchbay.DataCase, async: false

  import ExUnit.CaptureIO

  alias Patchbay.Forum
  alias Patchbay.Forum.Tool
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest
  alias Patchbay.Repo.Migrations.FillToolRetirement

  @version 20_261_112_142_733

  test "after the fill, every site offers the tools the old rule offered" do
    whole = Forum.register_site!("whole.example")
    book = seen!(whole, "book", description: "The book tool.")
    search_before = seen!(whole, "search")
    track = seen!(whole, "track")
    orders = seen!(whole, "orders", address: "https://whole.example/orders")
    checked!(whole, %{"page_complete" => true, "webmcp" => [found("book"), found("search")]})
    # The old check's own sightings, made once it kept its findings.
    assert seen!(whole, "book", description: "The book tool.").id == book.id
    search = seen!(whole, "search", description: "The search tool.")

    directory = Forum.register_site!("directory.example")

    Forum.upsert_catalog_entry!("directory.example", %{
      support_relationship: :site_tools,
      tool_inventory_status: :observed,
      last_verified_at: DateTime.utc_now()
    })

    directory_book = seen!(directory, "book")
    checked!(directory, %{"page_complete" => true, "webmcp" => [found("search")]})

    partial = Forum.register_site!("partial.example")
    partial_book = seen!(partial, "book")
    checked!(partial, %{"page_complete" => false, "webmcp" => [found("search")]})

    failed = Forum.register_site!("failed.example")
    failed_book = seen!(failed, "book")

    checked!(failed, %{
      "page_complete" => true,
      "webmcp" => [found("search")],
      "failed" => true
    })

    listed = Forum.register_site!("listed.example")
    listed_track = seen!(listed, "track")

    listed_search =
      Forum.publish_catalog_tool!(%{
        site_id: listed.id,
        address: page(listed),
        name: "search",
        contract_sha256: String.duplicate("c", 64),
        source_kind: :official,
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })

    listed_book = seen!(listed, "book")
    checked!(listed, %{"page_complete" => true, "webmcp" => [found("search")]})

    # Without the fill, the two tools the old rule hid would be offered again.
    assert current?(search_before) and current?(track)

    output = fill!()

    assert checks([whole, directory, partial, failed, listed]) == %{
             "whole.example" => {page(whole), checked_at(whole)},
             "directory.example" => {page(directory), checked_at(directory)},
             "partial.example" => {page(partial), nil},
             "failed.example" => {page(failed), nil},
             "listed.example" => {page(listed), checked_at(listed)}
           }

    whole_check = Forum.get_site_check!(whole.origin)
    listed_check = Forum.get_site_check!(listed.origin)

    # Each tool: {offered under the old rule, check_found_at, retired_at}.
    expected = %{
      "found by the whole check" => {book, {true, whole_check.checked_at, nil}},
      "the version the check found" => {search, {true, whole_check.checked_at, nil}},
      "an older version on the page" =>
        {search_before, {false, whole_check.checked_at, whole_check.page_read_at}},
      "missing from the page" => {track, {false, nil, whole_check.page_read_at}},
      "agents only, on another page" => {orders, {true, nil, nil}},
      "in the researched directory" => {directory_book, {true, nil, nil}},
      "after a partial read" => {partial_book, {true, nil, nil}},
      "after a failed check" => {failed_book, {true, nil, nil}},
      "on the published list" => {listed_search, {true, listed_check.checked_at, nil}},
      "seen since the list" => {listed_book, {true, nil, nil}},
      "seen before the list" => {listed_track, {false, nil, nil}}
    }

    assert Map.new(expected, fn {label, {tool, _}} -> {label, filled(tool)} end) ==
             Map.new(expected, fn {label, {_, values}} -> {label, values} end)

    # The release step's counts, before and after.
    assert output |> String.split("\n", trim: true) |> Enum.map(&numbers/1) == [
             [5, 0, 0, 11, 0, 0],
             [5, 5, 3, 11, 4, 2]
           ]
  end

  # An agent's sighting, keyed by the contract a check records for a page's
  # tool of that name and description.
  defp seen!(site, name, opts \\ []) do
    description = opts[:description]
    contract = %{"name" => name, "title" => nil, "description" => description}

    Forum.observe_tool!(%{
      site_id: site.id,
      address: opts[:address] || page(site),
      name: name,
      description: description,
      contract_sha256: contract |> CanonicalJSON.encode() |> Digest.sha256()
    })
  end

  defp found(name), do: %{"name" => name, "description" => "The #{name} tool."}

  # A finished check as the old job kept it: the page it read, and whether it
  # read it whole, only in its findings.
  defp checked!(site, findings) do
    check = Forum.request_site_check!(site.origin)

    Forum.record_site_check!(check, %{findings: Map.put(findings, "page_url", page(site))},
      authorize?: false
    )
  end

  defp page(site), do: "https://#{site.origin}/"

  defp checked_at(site), do: Forum.get_site_check!(site.origin).checked_at

  defp checks(sites) do
    Map.new(sites, fn site ->
      check = Forum.get_site_check!(site.origin)
      {site.origin, {check.page_url, check.page_read_at}}
    end)
  end

  defp current?(tool), do: Ash.get!(Tool, tool.id, load: [:current?]).current?

  defp filled(tool) do
    tool = Ash.get!(Tool, tool.id, load: [:current?])
    {tool.current?, tool.check_found_at, tool.retired_at}
  end

  defp numbers(line), do: for([n] <- Regex.scan(~r/\d+/, line), do: String.to_integer(n))

  # The test database ran the fill when it was set up, so it is taken off the
  # migrator's list first and its `up` runs again, here, over these rows. The
  # migrator runs it in a task of its own, which shares this test's connection,
  # so it takes no lock that would hold that connection.
  defp fill! do
    unless Code.ensure_loaded?(FillToolRetirement) do
      Repo
      |> Ecto.Migrator.migrations_path()
      |> Path.join("#{@version}_fill_tool_retirement.exs")
      |> Code.require_file()
    end

    capture_io(fn ->
      Ecto.Migrator.down(Repo, @version, FillToolRetirement, migration_lock: false, log: false)
      Ecto.Migrator.up(Repo, @version, FillToolRetirement, migration_lock: false, log: false)
    end)
  end
end
