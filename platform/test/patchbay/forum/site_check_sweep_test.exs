defmodule Patchbay.Forum.SiteCheckSweepTest do
  @moduledoc """
  Every ten minutes the next few listed domains no check has been asked for
  are asked for, in listing order, each with its check's job queued, so the
  whole directory is read in time without anyone opening its sites (PB-67).
  """

  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteCheck.Workers.Run
  alias Patchbay.Forum.{SiteCheckSweep, SiteDirectory}

  defp asked, do: Forum.list_asked_site_check_domains!() |> Enum.map(& &1.domain) |> Enum.sort()

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
end
