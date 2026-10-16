defmodule Patchbay.Forum.TakeSitePicture do
  @moduledoc """
  The `:take_picture` action of `Patchbay.Forum.Site`: has the screenshot
  machine take a picture of the site's page (`screenshot_source_url`: its
  front page, or the page its catalog entry names), keeps it, and points the
  site's card at it. A picture that does not come back is an error
  (`Patchbay.Forum.PictureNotTaken`), so its job tries again with Oban's
  backoff. When the page answers with an error status, the earlier picture
  is forgotten too, so the card never shows a page that now fails.
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
    now = DateTime.utc_now()

    with {:ok, image} <- picture(site),
         # Patchbay's own job: there is no actor for policies to check.
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
    |> logged()
  end

  # A site that is slow or failing leaves no picture; that is a site's doing,
  # not Patchbay's, so it is a warning that carries why.
  defp picture(site) do
    case Shots.take(site.screenshot_source_url) do
      {:ok, image} ->
        {:ok, image}

      {:error, reason} ->
        error = PictureNotTaken.exception(reason: reason)
        Logger.warning("#{site.origin}: " <> Exception.message(error))
        forget_on_page_status(site, reason)
        {:error, error}
    end
  end

  # Patchbay's own job: there is no actor for policies to check.
  defp forget_on_page_status(site, {:page_status, _status}) do
    SiteScreenshot
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.bulk_destroy!(:forget, %{}, authorize?: false)

    site
    |> Ash.Changeset.for_update(:forget_picture, %{})
    |> Ash.update!(authorize?: false)
  end

  defp forget_on_page_status(_site, _reason), do: :ok

  # The trigger leaves logging here, so a failure of Patchbay's own is still an
  # error, named by its kind.
  defp logged({:error, %PictureNotTaken{}} = refused), do: refused

  defp logged({:error, error} = failed) do
    Logger.error("A site's picture could not be kept", error_type: inspect(error.__struct__))
    failed
  end

  defp logged(updated), do: updated
end
