defmodule Patchbay.Forum.ListedSitePicture.Workers.Take do
  @moduledoc """
  One listed site's picture (`Patchbay.Forum.ListedSitePicture`'s `:take`),
  on the queue that takes every site's pictures one at a time. Like a
  board's picture it has three tries, and the last one keeps that no
  picture came back. One job per domain while it waits, runs or tries again.
  """

  use Oban.Worker,
    queue: :site_pictures,
    max_attempts: 3,
    unique: [keys: [:domain], period: :infinity, states: :incomplete]

  alias Patchbay.Forum

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain" => domain}, attempt: attempt, max_attempts: max}) do
    # Patchbay's own job: there is no actor for policies to check.
    with {:ok, _picture} <-
           Forum.take_listed_site_picture(domain, attempt == max, authorize?: false),
         do: :ok
  end
end
