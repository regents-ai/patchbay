defmodule Patchbay.Forum.TakeSitePicture do
  @moduledoc """
  The `:take_picture` action of `Patchbay.Forum.Site`: has the screenshot
  machine take a picture of the site's page (`screenshot_source_url`: its
  front page, or the page its catalog entry names), keeps it, and points the
  site's card at it.

  A page that answers with an error status has refused the picture, and
  asking again within a minute gets the same answer, so that is the outcome
  and the next try waits a day. The earlier picture is forgotten, so the card
  never shows a page that now fails, except after a 429: that is the site
  asking us to slow down, not a failing page. Any other picture that does not
  come back is an error (`Patchbay.Forum.PictureNotTaken`), and its job tries
  again with Oban's backoff.
  """

  use Ash.Resource.ManualUpdate

  require Ash.Query
  require Logger

  alias Patchbay.Forum.PictureNotTaken
  alias Patchbay.Forum.Shots
  alias Patchbay.Forum.SiteScreenshot

  @impl true
  def update(changeset, _opts, _context) do
    site = changeset.data

    case Shots.take(site.screenshot_source_url) do
      {:ok, image} -> keep(site, image)
      {:error, {:page_status, 429} = reason} -> slowed(site, reason)
      {:error, {:page_status, _status} = reason} -> refused(site, reason)
      {:error, reason} -> not_taken(site, reason)
    end
    |> logged()
  end

  # Patchbay's own job: there is no actor for policies to check.
  defp keep(site, image) do
    now = DateTime.utc_now()

    with {:ok, _picture} <-
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

  defp refused(site, reason) do
    warn(site, reason)

    SiteScreenshot
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.bulk_destroy!(:forget, %{}, authorize?: false)

    site
    |> Ash.Changeset.for_update(:forget_picture, %{})
    |> Ash.update(authorize?: false)
  end

  defp slowed(site, reason) do
    warn(site, reason)

    site
    |> Ash.Changeset.for_update(:picture_failed, %{})
    |> Ash.update(authorize?: false)
  end

  defp not_taken(site, reason) do
    warn(site, reason)
    {:error, PictureNotTaken.exception(reason: reason)}
  end

  # A site that is slow or failing leaves no picture; that is a site's doing,
  # not Patchbay's, so it is a warning that carries why.
  defp warn(site, reason) do
    error = PictureNotTaken.exception(reason: reason)
    Logger.warning("#{site.origin}: " <> Exception.message(error))
  end

  # The trigger leaves logging here, so a failure of Patchbay's own is still an
  # error, named by its kind.
  defp logged({:error, %PictureNotTaken{}} = not_taken), do: not_taken

  defp logged({:error, error} = failed) do
    Logger.error("A site's picture could not be kept", error_type: inspect(error.__struct__))
    failed
  end

  defp logged(updated), do: updated
end
