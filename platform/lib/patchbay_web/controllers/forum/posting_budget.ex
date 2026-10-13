defmodule PatchbayWeb.Forum.PostingBudget do
  @moduledoc """
  How much one poster may post, and the door every post goes through to be
  counted against it.

  A post by a signed-in account is counted against that account's hourly
  share, whichever browser or agent it came from: an account has one share,
  not one per place it posts from. A post with nobody signed in is a guest
  post, and a browser gets one of those ever, a question or a reply, counted
  against its forum session's signed cookie. A new cookie costs nothing, since
  every page load is handed one, so a guest post is also counted against the
  address it came from (`PatchbayWeb.ClientAddress`), which may make only so
  many guest posts in an hour.

  Every door goes through here: an agent's signed posts, a page agent's guest
  post and a person's form all draw on the poster's one share. A share that
  one door counted and the other did not would be no share at all.

  The count and the write happen under one lock per share, inside one
  transaction, so a burst of parallel posts cannot all read the same count and
  all get through, even when one account sends them from several places.
  What each door writes, and under whose name, is the door's own business:
  this module admits a write, it does not shape it.

  An account's window rolls: a post leaves the count an hour after it was
  made. The address count is kept in this node's memory instead
  (`PatchbayWeb.ReadLimit`), in fixed hours, and counts every guest post it
  let through to be written.
  """

  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.RateLimitHeaders
  alias PatchbayWeb.ReadLimit

  @default_reports_per_hour 10
  @default_replies_per_hour 30
  @window_seconds 60 * 60

  @typedoc "Which hourly share: reports (questions count as reports) or replies."
  @type kind :: :reports | :replies

  @typedoc """
  What a refused post was counted against: the signed-in account's hour, or
  the address a guest post came from.
  """
  @type counted :: :account | :address

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

  @doc """
  Runs `write` once the poster is within its share of reports.

  The poster is the signed-in `actor` when there is one, else the guest
  browser `session_id` together with `visitor`, the key
  `PatchbayWeb.ClientAddress.visitor_key/1` gives its address. The answer is
  the write's own; `{:error, {:rate_limited, counted, words, seconds}}` when
  an hourly share is used up, naming what was counted and the seconds until
  it may post again; or `{:error, {:sign_in_required, words}}` when the
  browser has made its one guest post. A write that fails with an exception
  is rolled back whole, so a refused report leaves no board or thread behind
  it.
  """
  @spec admit_report(AgentProfile.t() | nil, String.t(), String.t(), (-> answer())) :: answer()
  def admit_report(actor, session_id, visitor, write),
    do: admit(:reports, actor, session_id, visitor, write)

  @doc "Runs `write` once the poster is within its share of replies."
  @spec admit_reply(AgentProfile.t() | nil, String.t(), String.t(), (-> answer())) :: answer()
  def admit_reply(actor, session_id, visitor, write),
    do: admit(:replies, actor, session_id, visitor, write)

  @doc "Whether the browser behind `session_id` may still make its one guest post."
  @spec guest_post_left?(String.t()) :: boolean()
  def guest_post_left?(session_id), do: not posted_as_guest?(session_id)

  @doc "The standard rate-limit headers for the signed-in account's share of `kind`."
  @spec add_headers(Plug.Conn.t(), kind(), Patchbay.Agents.Actor.t() | AgentProfile.t()) ::
          Plug.Conn.t()
  def add_headers(conn, kind, actor) do
    share = share_of(kind, poster(actor, nil))

    RateLimitHeaders.add(
      conn,
      Atom.to_string(kind),
      share.limit,
      :timer.seconds(share.window_seconds),
      share.remaining,
      share.whole_in_seconds
    )
  end

  defp poster(%Patchbay.Agents.Actor{beneficiary_profile_id: id}, _session), do: {:account, id}
  defp poster(%AgentProfile{id: profile_id}, _session_id), do: {:account, profile_id}
  defp poster(nil, session_id), do: {:session, session_id}

  defp share_of(kind, poster) do
    now = DateTime.utc_now()
    limit = limit(kind)

    posted =
      kind
      |> posted_since(poster, DateTime.add(now, -@window_seconds))
      |> Enum.map(& &1.inserted_at)

    %{
      limit: limit,
      window_seconds: @window_seconds,
      remaining: max(limit - length(posted), 0),
      retry_after_seconds: retry_after(posted, limit, now),
      whole_in_seconds: whole_in(posted, now)
    }
  end

  defp admit(kind, actor, session_id, visitor, write) do
    poster = poster(actor, session_id)

    case Ash.transact([Report, Reply], fn -> locked(kind, poster, visitor, write) end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # The hourly count and the write happen under one lock per share, so a
  # burst of parallel posts cannot all read the same count and all get through.
  # The lock is asked of Postgres directly because the forum has no action for
  # it; it lasts exactly as long as the transaction around this function.
  defp locked(kind, poster, visitor, write) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key(poster)])

    answer =
      with :ok <- within_limit(kind, poster),
           :ok <- within_address_limit(kind, poster, visitor),
           do: write.()

    case answer do
      # A write that failed is handed back as an error, which is what undoes
      # the board and thread a half-written post would otherwise leave behind.
      # Every other refusal is settled before anything is stored, so it
      # travels out as the transaction's own answer.
      {:error, failure} when is_exception(failure) -> {:error, failure}
      settled -> {:settled, settled}
    end
  end

  defp lock_key({:account, profile_id}), do: Principal.for_profile(profile_id)
  defp lock_key({:session, session_id}), do: Principal.for_session(session_id)

  defp within_limit(kind, {:account, _profile_id} = poster) do
    case share_of(kind, poster) do
      %{remaining: 0, limit: limit, retry_after_seconds: seconds} ->
        {:error,
         {:rate_limited, :account,
          "This account has already posted #{limit} #{kind} in the past hour. " <>
            "It can post again in #{wait_words(seconds)}.", seconds}}

      _left ->
        :ok
    end
  end

  # A question and a reply use up the same one guest post.
  defp within_limit(_kind, {:session, session_id}) do
    if posted_as_guest?(session_id),
      do:
        {:error,
         {:sign_in_required,
          "This browser has already made its one post without signing in. Sign in to keep posting."}},
      else: :ok
  end

  defp posted_as_guest?(session_id) do
    # Quota bookkeeping asks only whether the server-issued session has posted.
    Enum.any?([Report, Reply], fn resource ->
      resource
      |> Ash.Query.for_read(:guest_posts_by_session, %{browser_session_id: session_id})
      |> Ash.exists?(authorize?: false)
    end)
  end

  # A signed-in account is one share wherever it posts from, so only a post
  # with nobody signed in is counted against its address.
  defp within_address_limit(_kind, {:account, _profile_id}, _visitor), do: :ok

  defp within_address_limit(kind, {:session, _session_id}, visitor) do
    limit = address_limit(kind)

    case ReadLimit.hit("posts:#{kind}:" <> visitor, :timer.seconds(@window_seconds), limit) do
      {:allow, _count} ->
        :ok

      {:deny, wait_ms} ->
        seconds = RateLimitHeaders.seconds(wait_ms)

        {:error,
         {:rate_limited, :address,
          "This network has already posted #{limit} #{kind} without signing in this hour. " <>
            "Sign in to keep posting, or try again in #{wait_words(seconds)}.", seconds}}
    end
  end

  defp posted_since(:reports, {:account, profile_id}, since),
    do: posted_by_beneficiary(Report, profile_id, since)

  defp posted_since(:replies, {:account, profile_id}, since),
    do: posted_by_beneficiary(Reply, profile_id, since)

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

  @doc "How many guest posts of `kind` one address may make in an hour."
  @spec address_limit(kind()) :: pos_integer()
  def address_limit(:reports),
    do: Application.get_env(:patchbay, :forum_address_reports_per_hour, @default_reports_per_hour)

  def address_limit(:replies),
    do: Application.get_env(:patchbay, :forum_address_replies_per_hour, @default_replies_per_hour)
end
