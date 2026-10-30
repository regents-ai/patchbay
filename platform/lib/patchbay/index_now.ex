defmodule Patchbay.IndexNow do
  @moduledoc """
  Tells the search engines that read IndexNow (Bing, which ChatGPT search reads,
  Yandex and others) which public pages are new or changed, so they read them
  again soon instead of on their own schedule.

  The key is the server setting `PATCHBAY_INDEXNOW_KEY`; with none set, nothing
  is sent and `/indexnow-key.txt` is not found. The key is public by design:
  that file serves it, which proves the list came from this site.

  Each release's pages are sent once: an hourly job queues one submission of the
  sitemap, unique to the running release. A thread that is posted, replied to
  or answered queues its own address in the same transaction
  (`Patchbay.Forum.Changes.AnnounceThread`).
  """
  use Oban.Worker, queue: :outside_calls, max_attempts: 5

  alias PatchbayWeb.SitemapController

  require Logger

  @endpoint "https://api.indexnow.org/indexnow"
  @key_path "/indexnow-key.txt"

  @doc "The site's IndexNow key, or nil when none is set."
  @spec key() :: String.t() | nil
  def key, do: Application.get_env(:patchbay, :indexnow_key)

  @doc "A job that sends `urls`, this site's own addresses (at most 10,000)."
  @spec submit([String.t()]) :: Oban.Job.changeset()
  def submit(urls), do: new(%{"urls" => urls})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"urls" => urls}}), do: deliver(key(), urls)

  # The hourly job: queue the sitemap once for each release, which is when the
  # fixed pages change. While the sitemap answers 503 it waits a minute and
  # tries again, so the release's one submission lists every page. After an
  # hour it stops, since the next hour's job has taken over.
  def perform(%Oban.Job{args: %{}, inserted_at: inserted_at}) do
    with key when is_binary(key) <- key(),
         {:ok, urls} <- SitemapController.urls() do
      %{"urls" => urls, "released" => SitemapController.released_at()}
      |> new(unique: [period: :infinity, keys: [:released], states: :all])
      |> Oban.insert!()

      :ok
    else
      nil ->
        :ok

      :unread ->
        if DateTime.diff(DateTime.utc_now(), inserted_at) < 3600, do: {:snooze, 60}, else: :ok
    end
  end

  defp deliver(nil, _urls), do: {:cancel, "no IndexNow key is set"}

  defp deliver(key, urls) do
    site = PatchbayWeb.Endpoint.url()

    body = %{
      host: URI.parse(site).host,
      key: key,
      keyLocation: site <> @key_path,
      urlList: urls
    }

    request =
      Req.new(url: @endpoint, retry: false, redirect: false, receive_timeout: 15_000)
      |> Req.merge(Application.get_env(:patchbay, :indexnow_req, []))

    case Req.post(request, json: body) do
      {:ok, %{status: status}} when status in [200, 202] ->
        Logger.info("IndexNow answered #{status} for #{length(urls)} pages")
        :ok

      {:ok, %{status: 429}} ->
        {:snooze, 600}

      # A list the engines refuse (a bad request, a key they could not read, or an
      # address that is not this site's) fails again on every attempt.
      {:ok, %{status: status}} when status in [400, 403, 422] ->
        {:cancel, "IndexNow answered #{status}"}

      {:ok, %{status: status}} ->
        {:error, "IndexNow answered #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end
end
