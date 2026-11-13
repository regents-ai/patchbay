defmodule Patchbay.Incidents.CveNow do
  @moduledoc """
  cve.now's critical and actively exploited records, each copied into a post
  on cve.now's board in Patchbay's own name (`Patchbay.Incidents.CveNow.Post`).
  The posts are advisories, news rather than questions
  (`Patchbay.Forum.Types.SourceKind`): they show on cve.now's board and the
  home page's Advisories tab as they are written, `/incidents` lists them
  after the incidents, and they never wait for an answer.

  One job runs every fifteen minutes (config/config.exs). It reads the newest
  page of `GET /api/v1/entries?filter=critical,kev` and works through it
  oldest first: a record with no post gets one, and a record cve.now changed
  since it was copied has its post brought in line. Nothing older than that
  page is read, so the first run copies that page and nothing before it. A
  run reads at most `:reads_per_run` records in full; the rest wait for the
  next run.

  A record has one post for good: the post carries the record's id under a
  unique index, and Oban runs one job at a time. A read that fails, answers
  anything but 200 or comes from cve.now's stale copy (`X-Cve-Now-Stale`)
  ends the run where it stands, and the next run starts again. When cve.now
  asks, with Retry-After, for longer than the time to the next run, the job
  waits that long instead. A record that is not in the expected shape, or
  that cve.now no longer rates critical, is passed over.
  """

  use Oban.Worker,
    queue: :outside_calls,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Patchbay.Config
  alias Patchbay.Forum
  alias Patchbay.Incidents.CveNow.Post

  require Logger

  # How often the job runs: the cron line in config/config.exs.
  @every_seconds 15 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if settings()[:enabled?], do: copy_newest(), else: :ok
  end

  defp copy_newest do
    with {:ok, %{"items" => items}} when is_list(items) <-
           read("/entries", filter: "critical,kev", limit: settings()[:page_size]),
         listed = items |> Enum.reverse() |> Enum.flat_map(&listed/1),
         {:ok, posts} <- Forum.list_cve_now_mirrors(Enum.map(listed, & &1.id)) do
      posts = Map.new(posts, &{&1.cve_now_id, &1})

      listed
      |> Enum.reject(&copied?(&1, posts[&1.id]))
      |> Enum.take(settings()[:reads_per_run])
      |> Enum.reduce_while(:ok, fn record, :ok -> copy(record, posts[record.id]) end)
    else
      stop -> stopped(stop)
    end
  end

  # What the list says about a record: its id and when it last changed.
  defp listed(%{"id" => id, "modifiedAt" => modified})
       when is_binary(id) and is_binary(modified) do
    case DateTime.from_iso8601(modified) do
      {:ok, modified_at, _offset} ->
        [%{id: id, modified_at: modified_at}]

      {:error, _reason} ->
        passed_over(id, :malformed)
        []
    end
  end

  defp listed(_item) do
    passed_over(nil, :malformed)
    []
  end

  defp copied?(_record, nil), do: false

  defp copied?(record, post),
    do: DateTime.compare(record.modified_at, post.cve_now_modified_at) != :gt

  defp copy(record, post) do
    case read("/entries/" <> URI.encode(record.id, &URI.char_unreserved?/1), []) do
      {:ok, entry} ->
        write(Post.from_entry(entry), record, post)
        {:cont, :ok}

      {:error, :not_found} ->
        passed_over(record.id, :not_found)
        {:cont, :ok}

      stop ->
        {:halt, stopped(stop)}
    end
  end

  defp write({:ok, %{id: id} = copy}, %{id: id}, post) do
    case save(copy, post) do
      {:ok, _post} -> :ok
      {:error, %type{}} -> passed_over(id, type)
    end
  end

  defp write({:ok, _copy_of_another_record}, record, _post),
    do: passed_over(record.id, :malformed)

  defp write({:error, reason}, record, _post), do: passed_over(record.id, reason)

  defp save(copy, nil) do
    with {:ok, site} <- Forum.register_site("cve.now"),
         {:error, refused} <-
           Forum.mirror_cve_now(%{
             site_id: site.id,
             title: copy.title,
             body_markdown: copy.body,
             topic_tags: [copy.tag],
             browser_session_id: Config.agent_session_id(),
             cve_now_id: copy.id,
             cve_now_modified_at: copy.modified_at
           }) do
      # Another run copied it first; its post is the one.
      case Forum.list_cve_now_mirrors([copy.id]) do
        {:ok, [post]} -> {:ok, post}
        {:ok, []} -> {:error, refused}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp save(copy, post) do
    Forum.refresh_cve_now(post, %{
      title: copy.title,
      body_markdown: copy.body,
      cve_now_modified_at: copy.modified_at
    })
  end

  defp read(path, params) do
    [
      base_url: settings()[:url],
      url: path,
      params: params,
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(Application.get_env(:patchbay, :cve_now_req_options, []))
    |> Req.get()
    |> answer()
  end

  defp answer({:ok, %Req.Response{status: 200} = response}) do
    case Req.Response.get_header(response, "x-cve-now-stale") do
      [] -> {:ok, response.body}
      _stale -> {:error, :stale}
    end
  end

  defp answer({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

  defp answer({:ok, %Req.Response{status: status} = response}) do
    case Req.Response.get_header(response, "retry-after") do
      [seconds] -> waited(Integer.parse(seconds), status)
      _none -> {:error, {:status, status}}
    end
  end

  defp answer({:error, exception}), do: {:error, exception}

  # Retry-After in whole seconds; anything shorter than the time to the next
  # run is kept by that run.
  defp waited({seconds, ""}, _status) when seconds > @every_seconds,
    do: {:error, {:wait, seconds}}

  defp waited(_seconds, status), do: {:error, {:status, status}}

  defp stopped({:error, {:wait, seconds}}) do
    Logger.warning("cve.now asked to wait #{seconds} seconds before the next read")
    {:snooze, seconds}
  end

  defp stopped(stop) do
    Logger.warning("cve.now could not be read; the next run tries again",
      error_type: reason(stop)
    )

    :ok
  end

  defp reason({:error, %type{}}), do: inspect(type)
  defp reason({:error, reason}), do: inspect(reason)
  defp reason({:ok, _answer}), do: "unexpected answer"

  defp passed_over(id, reason) do
    Logger.warning("cve.now record #{inspect(id)} passed over", error_type: inspect(reason))
  end

  defp settings, do: Application.fetch_env!(:patchbay, __MODULE__)
end
