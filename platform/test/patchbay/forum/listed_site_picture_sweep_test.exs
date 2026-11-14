defmodule Patchbay.Forum.ListedSitePictureSweepTest do
  @moduledoc """
  Every five minutes Patchbay queues pictures of the home pages of a few
  listed sites that have none, in listing order, on the queue that takes
  every site's pictures one at a time. A site with a board is left to its
  board's picture; a site whose picture is kept, or whose last try kept that
  none came back, is not asked for again. A run while earlier pictures still
  wait queues nothing more for them. The switch stops the queueing. Each run
  counts, for the private metrics listener, how many listed sites show a
  picture, how many failed and how many wait, and the bytes of every site
  picture stored.
  """

  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  @moduletag :capture_log

  alias Patchbay.Forum
  alias Patchbay.Forum.ListedSitePicture.Workers.Take
  alias Patchbay.Forum.{ListedSitePictureSweep, SiteDirectory}
  alias PatchbayWeb.Telemetry

  @picture "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "

  setup do
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)
    shots_answer(200, @picture)
  end

  # The screenshot machine answers every picture asked for with `status`.
  defp shots_answer(status, body) do
    test = self()

    Application.put_env(:patchbay, :shots_req_options,
      plug: fn conn ->
        {:ok, request, conn} = Plug.Conn.read_body(conn)
        send(test, {:shot, Jason.decode!(request)["url"]})
        Plug.Conn.send_resp(conn, status, body)
      end
    )
  end

  defp per_run, do: Application.fetch_env!(:patchbay, ListedSitePictureSweep)[:per_run]

  defp queued, do: all_enqueued(worker: Take) |> Enum.map(& &1.args["domain"]) |> Enum.sort()

  defp switch(settings) do
    old = Application.fetch_env!(:patchbay, ListedSitePictureSweep)
    on_exit(fn -> Application.put_env(:patchbay, ListedSitePictureSweep, old) end)
    Application.put_env(:patchbay, ListedSitePictureSweep, Keyword.merge(old, settings))
  end

  # A picture kept for `domain`, as its job keeps one.
  defp taken!(domain) do
    assert :ok = perform_job(Take, %{domain: domain})
    assert_received {:shot, _url}
  end

  # A try at `domain` whose page refused the picture, as its job keeps it.
  defp refused!(domain) do
    shots_answer(422, Jason.encode!(%{page_status: 403}))
    assert :ok = perform_job(Take, %{domain: domain})
    shots_answer(200, @picture)
  end

  # A board's picture, written as TakeSitePicture writes it: Patchbay's own
  # job, with no actor for policies to check. The job is not under test here.
  defp board_pictured!(domain, image) do
    site = Forum.register_site!(domain)

    Ash.create!(
      Patchbay.Forum.SiteScreenshot,
      %{site_id: site.id, image: image, captured_at: DateTime.utc_now()},
      action: :store,
      authorize?: false
    )

    Ash.update!(
      site,
      %{
        screenshot_path: "/site-screenshots/#{site.id}",
        screenshot_captured_at: DateTime.utc_now()
      },
      action: :record_screenshot,
      authorize?: false
    )
  end

  # A board whose last try failed, written as the picture trigger's last
  # failed try writes it (as above, no actor).
  defp board_failed!(domain) do
    domain
    |> Forum.register_site!()
    |> Ash.update!(%{}, action: :picture_failed, authorize?: false)
  end

  # What the operator reads from the private metrics listener.
  defp metric(name) do
    Telemetry.scrape()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, " ") do
        [^name, number] -> number |> Float.parse() |> elem(0) |> trunc()
        _other -> nil
      end
    end)
  end

  test "each run queues the next listed sites without a picture, in order, on the one-at-a-time queue" do
    {first, rest} = Enum.split(SiteDirectory.domains(), per_run())

    assert :ok = perform_job(ListedSitePictureSweep, %{})

    assert queued() == Enum.sort(first)
    assert Enum.all?(all_enqueued(worker: Take), &(&1.queue == "site_pictures"))
    # Every site's picture, a board's or a listed site's, is taken on that queue.
    assert Application.fetch_env!(:patchbay, Oban)[:queues][:site_pictures] == 1

    # While those wait, a run queues nothing more for them.
    assert :ok = perform_job(ListedSitePictureSweep, %{})
    assert queued() == Enum.sort(first)

    # Once they are taken, the next run moves on to the next sites.
    Enum.each(first, &taken!/1)
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(ListedSitePictureSweep, %{})
    assert queued() == rest |> Enum.take(per_run()) |> Enum.sort()
  end

  test "a site with a board, a kept picture or a failed try is passed over" do
    [board, kept, failed | rest] = SiteDirectory.domains()

    Forum.register_site!(board)
    taken!(kept)
    refused!(failed)

    assert :ok = perform_job(ListedSitePictureSweep, %{})

    assert queued() == rest |> Enum.take(per_run()) |> Enum.sort()
  end

  test "the count per run is the configured one" do
    switch(per_run: 1)

    assert :ok = perform_job(ListedSitePictureSweep, %{})

    assert queued() == [hd(SiteDirectory.domains())]
  end

  test "switched off, a run queues nothing and still counts" do
    switch(enabled?: false)
    [domain | _] = SiteDirectory.domains()
    taken!(domain)

    assert :ok = perform_job(ListedSitePictureSweep, %{})

    assert queued() == []
    assert metric("patchbay_site_pictures_pictured") == 1
  end

  test "only one run waits at a time" do
    assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(ListedSitePictureSweep.new(%{}))
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ListedSitePictureSweep.new(%{}))
    assert [_one] = all_enqueued(worker: ListedSitePictureSweep)
  end

  test "a picture of the home page is kept, and served for the site's row" do
    [domain | _] = SiteDirectory.domains()

    assert :ok = perform_job(Take, %{domain: domain})

    assert_received {:shot, url}
    assert url == "https://" <> domain <> "/"
    assert {:ok, %{image: @picture}} = Forum.get_listed_site_picture(domain)
  end

  test "a page that refuses is kept as failed at once, and the site is not asked again" do
    [domain | _] = SiteDirectory.domains()
    shots_answer(422, Jason.encode!(%{page_status: 403}))

    assert :ok = perform_job(Take, %{domain: domain})

    assert_received {:shot, _url}
    assert {:error, _none} = Forum.get_listed_site_picture(domain)
    assert [%{domain: ^domain, pictured?: false}] = Forum.list_kept_listed_site_pictures!()

    assert :ok = perform_job(ListedSitePictureSweep, %{})
    refute domain in queued()
  end

  test "any other failure tries again, and the last try keeps that none came back" do
    [domain | _] = SiteDirectory.domains()
    shots_answer(502, "")

    assert {:error, _not_taken} = perform_job(Take, %{domain: domain}, attempt: 1)
    assert {:error, _not_taken} = perform_job(Take, %{domain: domain}, attempt: 2)
    assert Forum.list_kept_listed_site_pictures!() == []

    assert :ok = perform_job(Take, %{domain: domain}, attempt: 3)
    assert [%{domain: ^domain, pictured?: false}] = Forum.list_kept_listed_site_pictures!()

    # A later picture that comes back replaces the failure.
    shots_answer(200, @picture)
    assert :ok = perform_job(Take, %{domain: domain})
    assert [%{pictured?: true}] = Forum.list_kept_listed_site_pictures!()
  end

  test "each run counts the listed sites with a picture, failed and waiting, and the bytes stored" do
    [board_pictured, board_failed, board_waiting, own, own_failed, both | _] =
      SiteDirectory.domains()

    board_image = :binary.copy("b", 1_000)
    board_pictured!(board_pictured, board_image)
    board_failed!(board_failed)
    Forum.register_site!(board_waiting)
    taken!(own)
    refused!(own_failed)
    # A picture taken before the site had a board: the row shows the board's.
    taken!(both)
    Forum.register_site!(both)
    # A board picture of a site that is not listed is stored all the same.
    board_pictured!("unlisted.example", :binary.copy("u", 500))

    assert :ok = perform_job(ListedSitePictureSweep, %{})

    listed = length(SiteDirectory.domains())
    assert metric("patchbay_site_pictures_pictured") == 2
    assert metric("patchbay_site_pictures_failed") == 2
    assert metric("patchbay_site_pictures_waiting") == listed - 4
    assert metric("patchbay_site_pictures_bytes") == 1_000 + 500 + 2 * byte_size(@picture)
  end
end
