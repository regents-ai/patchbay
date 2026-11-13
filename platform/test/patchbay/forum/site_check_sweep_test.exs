defmodule Patchbay.Forum.SiteCheckSweepTest do
  @moduledoc """
  Every five minutes Patchbay asks for checks of a few listed sites without
  anyone opening them, each with its check's job queued: first those no
  check has been asked for, in listing order (PB-67), then those due again,
  the longest unchecked first. A site whose check is on its way, or was
  checked within the day, is passed over. A check that cannot finish keeps
  what the last one found, and the site comes due again a day later. The
  switch stops the asking.
  """

  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  @moduletag :capture_log

  alias Patchbay.Forum
  alias Patchbay.Forum.{SiteCheck, SiteCheckSweep, SiteDirectory}
  alias Patchbay.Forum.SiteCheck.Workers.Run
  alias Patchbay.PageSite
  alias Patchbay.Repo

  defp asked, do: Forum.list_asked_site_check_domains!() |> Enum.map(& &1.domain) |> Enum.sort()

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600)

  # Every listed domain but `except` was checked an hour ago and read its
  # directory pages, so none of them is due.
  defp checked_all!(except) do
    rows =
      for domain <- SiteDirectory.domains(), domain not in except do
        %{
          domain: domain,
          findings: %{"directory" => %{}},
          requested_at: ago(2),
          checked_at: ago(1)
        }
      end

    Repo.insert_all("site_checks", rows)
  end

  # A finished check of `domain`, last checked `hours` ago.
  defp checked!(domain, hours, findings \\ %{"directory" => %{}}) do
    Repo.insert_all("site_checks", [
      %{domain: domain, findings: findings, requested_at: ago(hours + 1), checked_at: ago(hours)}
    ])
  end

  defp on_its_way,
    do: SiteCheck |> Ash.read!() |> Enum.filter(&SiteCheck.pending?/1) |> Enum.map(& &1.domain)

  defp run_check_ids, do: Enum.map(all_enqueued(worker: Run), & &1.args["primary_key"]["id"])

  test "each run asks for the next listed domains, in order, each with its check queued" do
    {first, rest} = Enum.split(SiteDirectory.domains(), SiteCheckSweep.batch())

    assert :ok = perform_job(SiteCheckSweep, %{})
    assert asked() == Enum.sort(first)
    assert length(all_enqueued(worker: Run)) == SiteCheckSweep.batch()

    assert :ok = perform_job(SiteCheckSweep, %{})
    assert asked() == Enum.sort(first ++ Enum.take(rest, SiteCheckSweep.batch()))
  end

  test "a domain someone already asked for is passed over, and not asked again" do
    [opened | _] = SiteDirectory.domains()
    Forum.request_site_check!(opened)
    {:ok, check} = Forum.get_site_check(opened)

    assert :ok = perform_job(SiteCheckSweep, %{})

    assert length(asked()) == SiteCheckSweep.batch() + 1
    assert {:ok, ^check} = Forum.get_site_check(opened)
  end

  test "once every site has been asked for, the sites due again go first, longest unchecked first" do
    [eight, six, four, two, day_and_half, no_pages, waiting | _] = SiteDirectory.domains()
    checked_all!([eight, six, four, two, day_and_half, no_pages, waiting])

    checked!(eight, 8 * 24)
    checked!(six, 6 * 24)
    checked!(four, 4 * 24)
    checked!(two, 2 * 24)
    checked!(day_and_half, 36)
    # Read an hour ago, but none of its directory pages: due at once.
    checked!(no_pages, 1, %{"webmcp" => []})
    # Checked nine days ago, with a check on its way since.
    checked!(waiting, 9 * 24)
    Forum.request_site_check!(waiting)
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(SiteCheckSweep, %{})

    assert Enum.sort(on_its_way()) == Enum.sort([eight, six, four, two, day_and_half, waiting])
    assert length(run_check_ids()) == SiteCheckSweep.batch()

    # The next round asks for the one left, never one already on its way.
    assert :ok = perform_job(SiteCheckSweep, %{})

    assert no_pages in on_its_way()
    ids = run_check_ids()
    assert length(ids) == SiteCheckSweep.batch() + 1
    assert ids == Enum.uniq(ids)

    # Nothing else is due.
    assert :ok = perform_job(SiteCheckSweep, %{})
    assert length(run_check_ids()) == SiteCheckSweep.batch() + 1
  end

  test "only one round waits at a time" do
    assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(SiteCheckSweep.new(%{}))
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(SiteCheckSweep.new(%{}))
    assert [_one] = all_enqueued(worker: SiteCheckSweep)
  end

  test "a check that cannot finish keeps what the last one found, and comes due a day later" do
    domain = "target.com"
    pages = SiteDirectory.pages(domain)
    checked_all!([domain])

    PageSite.serve(Map.new(pages, &{URI.parse(&1).path, PageSite.with_tool("search_products")}))
    Forum.request_site_check!(domain)
    Oban.drain_queue(queue: :site_checks)

    {:ok, %{sites: [before]}} = SiteDirectory.page(%{"q" => "target.com"})
    assert [%{"name" => "search_products"} | _] = before.tools

    # A day and a half later the site is due, and every page fails to answer.
    Repo.query!(
      "UPDATE site_checks SET requested_at = requested_at - interval '36 hours', " <>
        "checked_at = checked_at - interval '36 hours' WHERE domain = $1",
      [domain]
    )

    PageSite.serve(%{})
    assert :ok = perform_job(SiteCheckSweep, %{})
    assert [domain] == on_its_way()
    Oban.drain_queue(queue: :site_checks)

    {:ok, %{sites: [after_failure]}} = SiteDirectory.page(%{"q" => "target.com"})
    assert after_failure.tools == before.tools
    assert after_failure.checked_at == before.checked_at

    # Not asked for again until a day after the failed try.
    {:ok, check} = Forum.get_site_check(domain)
    refute SiteCheck.due?(check)
    Repo.delete_all(Oban.Job)
    assert :ok = perform_job(SiteCheckSweep, %{})
    assert all_enqueued(worker: Run) == []
  end

  test "switched off, a round asks for nothing" do
    old = Application.fetch_env!(:patchbay, SiteCheckSweep)
    on_exit(fn -> Application.put_env(:patchbay, SiteCheckSweep, old) end)
    Application.put_env(:patchbay, SiteCheckSweep, enabled?: false)

    assert :ok = perform_job(SiteCheckSweep, %{})

    assert asked() == []
    assert all_enqueued(worker: Run) == []
  end
end
