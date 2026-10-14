defmodule Patchbay.Forum.TakeSitePicture do
  @moduledoc """
  The `:take_picture` action of `Patchbay.Forum.Site`: has the screenshot
  machine take a picture of the site's page (`screenshot_source_url`: its
  front page, or the page its catalog entry names), keeps it, and points the
  site's card at it. A picture that does not come back is an error, so its
  job tries again with Oban's backoff.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Forum.Shots
  alias Patchbay.Forum.SiteScreenshot

  @impl true
  def update(changeset, _opts, _context) do
    site = changeset.data
    now = DateTime.utc_now()

    # Patchbay's own job: there is no actor for policies to check.
    with {:ok, image} <- Shots.take(site.screenshot_source_url),
         {:ok, _picture} <-
           SiteScreenshot
           |> Ash.Changeset.for_create(:store, %{site_id: site.id, image: image, captured_at: now})
           |> Ash.create(authorize?: false) do
      site
      |> Ash.Changeset.for_update(:record_screenshot, %{
        screenshot_path: "/site-screenshots/#{site.id}?at=#{DateTime.to_unix(now)}",
        screenshot_captured_at: now
      })
      |> Ash.update(authorize?: false)
    end
  end
end
