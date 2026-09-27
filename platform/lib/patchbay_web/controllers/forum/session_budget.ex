defmodule PatchbayWeb.Forum.SessionBudget do
  @moduledoc """
  How much one browser may post in an hour, and the door every post goes
  through to be counted against it.

  A report or a reply is filed under the browser's forum session whichever
  way it arrives. An agent posts through the page's tools and a person posts
  through the form on the report page, but both run in the same browser under
  the same signed session, so both draw on the same hourly share. A share that
  one door counted and the other did not would be no share at all.

  The count and the write happen under one lock per session, inside one
  transaction, so a burst of parallel posts cannot all read the same count and
  all get through. What each door writes, and under whose name, is the door's
  own business: this module admits a write, it does not shape it.

  The share belongs to the session, never to the person: a hosted MCP
  connection's session (its `Mcp-Session-Id`) has the same share as a
  browser's, and signing in does not join one browser's share to another's.
  The window rolls: a post leaves the count an hour after it was made.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias PatchbayWeb.RateLimitHeaders

  @default_reports_per_hour 10
  @default_replies_per_hour 30
  @window_seconds 60 * 60

  @typedoc "Which hourly share: reports (questions count as reports) or replies."
  @type kind :: :reports | :replies

  @typedoc """
  One session's share as every door reports it: its size, its window in
  seconds, what is left, the seconds until one more post is allowed when
  nothing is left, and the seconds until the whole share is back.
  """
  @type share :: %{
          limit: pos_integer(),
          window_seconds: pos_integer(),
          remaining: non_neg_integer(),
          retry_after_seconds: pos_integer() | nil,
          whole_in_seconds: non_neg_integer()
        }

  @typedoc "What a write hands back once admitted, or why it was not admitted."
  @type answer :: {:ok, term()} | {:error, term()}

  @doc """
  Runs `write` once the session is within its hourly share of reports.

  The answer is the write's own, or `{:error, {:rate_limited, words, seconds}}`
  when the session has already filed its share, naming the seconds until it
  may post again. A write that fails with an exception is rolled back whole,
  so a refused report leaves no board or thread behind it.
  """
  @spec admit_report(String.t(), (-> answer())) :: answer()
  def admit_report(session_id, write), do: admit(:reports, session_id, write)

  @doc "Runs `write` once the session is within its hourly share of replies."
  @spec admit_reply(String.t(), (-> answer())) :: answer()
  def admit_reply(session_id, write), do: admit(:replies, session_id, write)

  @doc "The session's share of `kind` as it stands now."
  @spec share(kind(), String.t()) :: share()
  def share(kind, session_id) do
    now = DateTime.utc_now()
    limit = limit(kind)

    posted =
      kind
      |> posted_since(session_id, DateTime.add(now, -@window_seconds))
      |> Enum.map(& &1.inserted_at)

    %{
      limit: limit,
      window_seconds: @window_seconds,
      remaining: max(limit - length(posted), 0),
      retry_after_seconds: retry_after(posted, limit, now),
      whole_in_seconds: whole_in(posted, now)
    }
  end

  @doc "The standard rate-limit headers for the session's share of `kind`."
  @spec add_headers(Plug.Conn.t(), kind(), String.t()) :: Plug.Conn.t()
  def add_headers(conn, kind, session_id) do
    share = share(kind, session_id)

    RateLimitHeaders.add(
      conn,
      Atom.to_string(kind),
      share.limit,
      :timer.seconds(share.window_seconds),
      share.remaining,
      share.whole_in_seconds
    )
  end

  defp admit(kind, session_id, write) do
    case Ash.transact([Report, Reply], fn -> locked(kind, session_id, write) end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # The hourly count and the write happen under one per-session lock, so a
  # burst of parallel posts cannot all read the same count and all get through.
  # The lock is asked of Postgres directly because the forum has no action for
  # it; it lasts exactly as long as the transaction around this function.
  defp locked(kind, session_id, write) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [session_id])

    answer = with :ok <- within_limit(kind, session_id), do: write.()

    case answer do
      # A write that failed is handed back as an error, which is what undoes
      # the board and thread a half-written post would otherwise leave behind.
      # Every other refusal is settled before anything is stored, so it
      # travels out as the transaction's own answer.
      {:error, failure} when is_exception(failure) -> {:error, failure}
      settled -> {:settled, settled}
    end
  end

  defp within_limit(kind, session_id) do
    case share(kind, session_id) do
      %{remaining: 0, limit: limit, retry_after_seconds: seconds} ->
        {:error,
         {:rate_limited,
          "This session has already posted #{limit} #{kind} in the past hour. " <>
            "It can post again in #{wait_words(seconds)}.", seconds}}

      _left ->
        :ok
    end
  end

  defp posted_since(:reports, session_id, since),
    do: Forum.reports_posted_by_session!(session_id, since)

  defp posted_since(:replies, session_id, since),
    do: Forum.replies_posted_by_session!(session_id, since)

  # A post leaves the share an hour after it was made, oldest first, so the
  # next one is allowed when enough of the oldest have left to free one place.
  defp retry_after(posted, limit, now) when length(posted) >= limit do
    posted
    |> Enum.at(length(posted) - limit)
    |> seconds_until_it_leaves(now)
  end

  defp retry_after(_posted, _limit, _now), do: nil

  defp whole_in([], _now), do: 0
  defp whole_in(posted, now), do: posted |> List.last() |> seconds_until_it_leaves(now)

  defp seconds_until_it_leaves(inserted_at, now) do
    inserted_at
    |> DateTime.add(@window_seconds)
    |> DateTime.diff(now, :millisecond)
    |> max(0)
    |> RateLimitHeaders.seconds()
  end

  defp wait_words(seconds) when seconds <= 60, do: "a minute"
  defp wait_words(seconds), do: "#{ceil(seconds / 60)} minutes"

  @doc "How many of `kind` one session may post in any hour."
  @spec limit(kind()) :: pos_integer()
  def limit(:reports),
    do: Application.get_env(:patchbay, :forum_reports_per_hour, @default_reports_per_hour)

  def limit(:replies),
    do: Application.get_env(:patchbay, :forum_replies_per_hour, @default_replies_per_hour)
end
