defmodule PatchbayWeb.Forum.PostingBudget do
  @moduledoc """
  How much one account may post, and the door every post goes through to be
  read and counted.

  Only a signed-in account posts. Its posts are counted against its hourly
  share, whichever browser or agent they came from: an account has one share,
  not one per place it posts from, and a paired agent's posts count against
  its person's.

  Every door goes through here: an agent's signed posts and a person's form
  all draw on the one share, and every one of them is read first by
  `Patchbay.Forum.PostingCheck`. A share that one door counted and another
  did not would be no share at all, and the same goes for the reading.

  A post the write refuses for its own fields is refused before the reading,
  with the write's own words: each door hands over how its write is built,
  and the same build is checked first and made under the lock
  (`Patchbay.Forum.PostingCheck.admit/3`). The reading asks another service,
  so it happens before the transaction opens. The count and the write then
  happen under one lock per share, inside one transaction, so a burst of
  parallel posts cannot all read the same count and all get through, even
  when one account sends them from several places. What each door writes,
  and under whose name, is the door's own business: this module admits a
  write, it does not shape it.

  An account's window rolls: a post leaves the count an hour after it was
  made.
  """

  alias Patchbay.Agents.Actor
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.RateLimitHeaders

  @default_reports_per_hour 10
  @default_replies_per_hour 30
  @window_seconds 60 * 60

  @typedoc "Which hourly share: reports (questions count as reports) or replies."
  @type kind :: :reports | :replies

  @typedoc """
  One share as every door reports it: its size, its window in seconds, what
  is left, the seconds until one more post is allowed when nothing is left,
  and the seconds until the whole share is back.
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

  @typedoc "Makes the write a `t:Patchbay.Forum.PostingCheck.write/0` built."
  @type write :: (Ash.Changeset.t() -> answer())

  @doc """
  Builds the write with `build` and makes it with `write` once three things
  hold: the write, built first, does not refuse the post; `post`, the words
  about to be published, has been read and let through; and `actor` is
  within its share of reports.

  The answer is the write's own, or the write's own refusal of the post
  before it was read; `{:error, {:rate_limited, :account, words, seconds}}`
  when the hourly share is used up, with the seconds until the account may
  post again; or one of `t:Patchbay.Forum.PostingCheck.refusal/0` when the
  reading turned the post away, posting is paused, or the reading could not
  be done. A write that fails with an exception is rolled back whole, so a
  refused report leaves no board or thread behind it.
  """
  @spec admit_report(
          Actor.t() | AgentProfile.t(),
          PostingCheck.post(),
          PostingCheck.write(),
          write()
        ) :: answer()
  def admit_report(actor, post, build, write), do: admit(:reports, actor, post, build, write)

  @doc """
  The same for the new thread `draft` makes, whose write is built with the
  thread's type: the poster's pick, or what the reading made of the words
  when they picked none (`Patchbay.Forum.PostingCheck.admit_thread/3`).
  """
  @spec admit_thread(
          Actor.t() | AgentProfile.t(),
          map(),
          (String.t() | nil -> {:ok, Ash.Changeset.t()} | {:error, term()}),
          write()
        ) :: answer()
  def admit_thread(actor, draft, build, write) do
    account = account(actor)

    with :ok <- within_limit(:reports, account),
         {:ok, type} <- PostingCheck.admit_thread(actor, draft, build),
         do: under_lock(:reports, account, fn -> build.(type) end, write)
  end

  @doc "The same for a reply, within the account's share of replies."
  @spec admit_reply(
          Actor.t() | AgentProfile.t(),
          PostingCheck.post(),
          PostingCheck.write(),
          write()
        ) :: answer()
  def admit_reply(actor, post, build, write), do: admit(:replies, actor, post, build, write)

  @doc "The standard rate-limit headers for the signed-in account's share of `kind`."
  @spec add_headers(Plug.Conn.t(), kind(), Actor.t() | AgentProfile.t()) :: Plug.Conn.t()
  def add_headers(conn, kind, actor) do
    share = share_of(kind, account(actor))

    RateLimitHeaders.add(
      conn,
      Atom.to_string(kind),
      share.limit,
      :timer.seconds(share.window_seconds),
      share.remaining,
      share.whole_in_seconds
    )
  end

  # The account a post is counted against: the person's own, or the person a
  # paired agent posts for.
  defp account(%Actor{beneficiary_profile_id: id}), do: id
  defp account(%AgentProfile{id: id}), do: id

  defp share_of(kind, account) do
    now = DateTime.utc_now()
    limit = limit(kind)

    posted =
      kind
      |> posted_since(account, DateTime.add(now, -@window_seconds))
      |> Enum.map(& &1.inserted_at)

    %{
      limit: limit,
      window_seconds: @window_seconds,
      remaining: max(limit - length(posted), 0),
      retry_after_seconds: retry_after(posted, limit, now),
      whole_in_seconds: whole_in(posted, now)
    }
  end

  # The share is looked at once before the reading, so an account that has
  # used it up is told so without Jev being asked, and counted again under
  # the lock, which is the count that admits the write.
  defp admit(kind, actor, post, build, write) do
    account = account(actor)

    with :ok <- within_limit(kind, account),
         :ok <- PostingCheck.admit(actor, post, build),
         do: under_lock(kind, account, build, write)
  end

  defp under_lock(kind, account, build, write) do
    case Ash.transact([Report, Reply], fn -> locked(kind, account, build, write) end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # The hourly count and the write happen under one lock per share, so a
  # burst of parallel posts cannot all read the same count and all get through.
  # The lock is asked of Postgres directly because the forum has no action for
  # it; it lasts exactly as long as the transaction around this function.
  defp locked(kind, account, build, write) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      Principal.for_profile(account)
    ])

    answer =
      with :ok <- within_limit(kind, account),
           {:ok, changeset} <- build.(),
           do: write.(changeset)

    case answer do
      # A write that failed is handed back as an error, which is what undoes
      # the board and thread a half-written post would otherwise leave behind.
      # Every other refusal is settled before anything is stored, so it
      # travels out as the transaction's own answer.
      {:error, failure} when is_exception(failure) -> {:error, failure}
      settled -> {:settled, settled}
    end
  end

  defp within_limit(kind, account) do
    case share_of(kind, account) do
      %{remaining: 0, limit: limit, retry_after_seconds: seconds} ->
        {:error,
         {:rate_limited, :account,
          "This account has already posted #{limit} #{kind} in the past hour. " <>
            "It can post again in #{wait_words(seconds)}.", seconds}}

      _left ->
        :ok
    end
  end

  defp posted_since(:reports, account, since), do: posted_by_beneficiary(Report, account, since)
  defp posted_since(:replies, account, since), do: posted_by_beneficiary(Reply, account, since)

  defp posted_by_beneficiary(resource, id, since) do
    require Ash.Query

    # Quota bookkeeping reads only this server-resolved beneficiary's posts.
    resource
    |> Ash.Query.filter(
      (author_profile_id == ^id or beneficiary_profile_id == ^id) and inserted_at > ^since
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

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

  @doc "How many of `kind` one signed-in account may post in any hour."
  @spec limit(kind()) :: pos_integer()
  def limit(:reports),
    do: Application.get_env(:patchbay, :forum_reports_per_hour, @default_reports_per_hour)

  def limit(:replies),
    do: Application.get_env(:patchbay, :forum_replies_per_hour, @default_replies_per_hour)
end
