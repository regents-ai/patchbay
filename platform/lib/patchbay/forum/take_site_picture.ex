defmodule Patchbay.Forum.TakeSitePicture do
  @moduledoc """
  The `:take_picture` action of `Patchbay.Forum.Site`: has the screenshot
  machine take a picture of the site's page (`screenshot_source_url`: its
  front page, or the page its catalog entry names), keeps it, and points the
  site's card at it.

  The screenshot machine runs the browser, holds no keys and reaches only
  public sites; Patchbay receives nothing from it but the image.

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
  alias Patchbay.Forum.SiteScreenshot

  @max_bytes 3 * 1024 * 1024

  @impl true
  def update(changeset, _opts, _context) do
    site = changeset.data

    case shoot(site.screenshot_source_url) do
      {:ok, image} -> keep(site, image)
      {:error, {:page_status, 429} = reason} -> slowed(site, reason)
      {:error, {:page_status, _status} = reason} -> refused(site, reason)
      {:error, reason} -> not_taken(site, reason)
    end
    |> logged()
  end

  # A WebP picture of the page, or why none came back: the error status the
  # page itself answered with (`{:page_status, 403}`), the machine's status,
  # `:not_a_picture`, why the call ended (`:timeout`), or the exception Req
  # raised.
  defp shoot(page_url) do
    options =
      [
        url: Application.fetch_env!(:patchbay, :shots_url) <> "/shot",
        json: %{url: page_url},
        receive_timeout: 60_000,
        retry: false,
        decode_body: false,
        # The machine's private address on Fly is IPv6 only.
        connect_options: [transport_opts: [inet6: true]]
      ] ++ Application.get_env(:patchbay, :shots_req_options, [])

    case Req.post(options) do
      {:ok,
       %Req.Response{
         status: 200,
         body: <<"RIFF", _size::binary-size(4), "WEBP", _::binary>> = image
       }}
      when byte_size(image) <= @max_bytes ->
        {:ok, image}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :not_a_picture}

      # The page answered with an error status, so the machine took no picture of it.
      {:ok, %Req.Response{status: 422, body: body}} ->
        %{"page_status" => status} = Jason.decode!(body)
        {:error, {:page_status, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      # Why the call ended, such as :timeout.
      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, exception} ->
        {:error, exception}
    end
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

  # As in keep/2: Patchbay's own job, with no actor for policies to check.
  defp refused(site, reason) do
    warn(site, reason)

    SiteScreenshot
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.bulk_destroy!(:forget, %{}, authorize?: false)

    site
    |> Ash.Changeset.for_update(:forget_picture, %{})
    |> Ash.update(authorize?: false)
  end

  # As in keep/2.
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
