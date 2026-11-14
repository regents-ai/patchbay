defmodule Patchbay.Forum.ListedSitePictureSweep do
  @moduledoc """
  Patchbay's own pictures of the listed sites that have none, without anyone
  asking. Every five minutes (config/config.exs) it queues a picture of the
  home page of the next `per_run` listed domains, in listing order
  (`Patchbay.Forum.ListedSitePicture`). It passes over a domain with a board
  of its own, whose picture the board's trigger takes (`Patchbay.Forum.Site`),
  a domain whose picture is kept, and a domain whose last try kept that no
  picture came back: that one is not asked for again.

  Each picture is its own job (`Patchbay.Forum.ListedSitePicture.Workers.Take`)
  on `site_pictures`, the queue that takes every site's pictures one at a
  time. A domain has one job while it waits, runs or tries again, so a run
  that finds the last run's domains still waiting adds nothing for them, and
  no more than `per_run` of these pictures ever wait at once. The run itself
  is on `default`, so it never takes the picture queue's one place.

  Each run also measures what is kept (`[:patchbay, :site_pictures]`, on the
  private metrics listener): of the listed domains, how many show a picture,
  how many failed and how many wait for one, and the bytes of every site
  picture stored, the boards' included.

  `enabled?: false` stops the queueing; pictures already queued still run,
  and the measuring goes on.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Patchbay.Forum
  alias Patchbay.Forum.ListedSitePicture
  alias Patchbay.Forum.ListedSitePicture.Workers.Take
  alias Patchbay.Forum.SiteDirectory
  alias Patchbay.Forum.SiteScreenshot

  @impl Oban.Worker
  def perform(_job) do
    config = Application.fetch_env!(:patchbay, __MODULE__)
    domains = SiteDirectory.domains()
    boards = Forum.list_site_picture_states!(domains)
    kept = Forum.list_kept_listed_site_pictures!()

    measure(domains, boards, kept)
    if config[:enabled?], do: queue(domains, boards, kept, config[:per_run])
    :ok
  end

  defp queue(domains, boards, kept, count) do
    done = MapSet.new(Enum.map(boards, & &1.origin) ++ Enum.map(kept, & &1.domain))

    domains
    |> Stream.reject(&MapSet.member?(done, &1))
    |> Enum.take(count)
    |> Enum.each(&Oban.insert!(Take.new(%{domain: &1})))
  end

  # A listed domain with a board shows the board's picture; one without
  # shows its own.
  defp measure(domains, boards, kept) do
    listed = MapSet.new(domains)
    with_board = MapSet.new(boards, & &1.origin)

    own =
      Enum.filter(
        kept,
        &(MapSet.member?(listed, &1.domain) and not MapSet.member?(with_board, &1.domain))
      )

    pictured =
      Enum.count(boards, &(not is_nil(&1.screenshot_captured_at))) +
        Enum.count(own, & &1.pictured?)

    failed =
      Enum.count(
        boards,
        &(is_nil(&1.screenshot_captured_at) and not is_nil(&1.picture_failed_at))
      ) +
        Enum.count(own, &(not &1.pictured?))

    :telemetry.execute(
      [:patchbay, :site_pictures],
      %{
        pictured: pictured,
        failed: failed,
        waiting: MapSet.size(listed) - pictured - failed,
        bytes: bytes(SiteScreenshot) + bytes(ListedSitePicture)
      },
      %{}
    )
  end

  defp bytes(resource),
    do: Ash.aggregate!(resource, {:bytes, :sum, field: :bytes, default: 0}).bytes
end
