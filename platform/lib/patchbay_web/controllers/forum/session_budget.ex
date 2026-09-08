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
  """

  require Ash.Query

  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @default_reports_per_hour 10
  @default_replies_per_hour 30

  @typedoc "What a write hands back once admitted, or why it was not admitted."
  @type answer :: {:ok, term()} | {:error, term()}

  @doc """
  Runs `write` once the session is within its hourly share of reports.

  The answer is the write's own, or `{:error, {:rate_limited, words}}` when
  the session has already filed its share. A write that fails with an
  exception is rolled back whole, so a refused report leaves no board or
  thread behind it.
  """
  @spec admit_report(String.t(), (-> answer())) :: answer()
  def admit_report(session_id, write) do
    admit(Report, session_id, reports_per_hour(), "reports", write)
  end

  @doc "Runs `write` once the session is within its hourly share of replies."
  @spec admit_reply(String.t(), (-> answer())) :: answer()
  def admit_reply(session_id, write) do
    admit(Reply, session_id, replies_per_hour(), "replies", write)
  end

  defp admit(resource, session_id, limit, subject, write) do
    case Ash.transact([Report, Reply], fn ->
           locked(resource, session_id, limit, subject, write)
         end) do
      {:ok, {:settled, answer}} -> answer
      {:error, failed_write} -> {:error, failed_write}
    end
  end

  # The hourly count and the write happen under one per-session lock, so a
  # burst of parallel posts cannot all read the same count and all get through.
  # The lock is asked of Postgres directly because the forum has no action for
  # it; it lasts exactly as long as the transaction around this function.
  defp locked(resource, session_id, limit, subject, write) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [session_id])

    answer = with :ok <- within_limit(resource, session_id, limit, subject), do: write.()

    case answer do
      # A write that failed is handed back as an error, which is what undoes
      # the board and thread a half-written post would otherwise leave behind.
      # Every other refusal is settled before anything is stored, so it
      # travels out as the transaction's own answer.
      {:error, failure} when is_exception(failure) -> {:error, failure}
      settled -> {:settled, settled}
    end
  end

  defp within_limit(resource, session_id, limit, subject) do
    since = DateTime.add(DateTime.utc_now(), -1, :hour)

    count =
      resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(browser_session_id == ^session_id and inserted_at > ^since)
      |> Ash.count!()

    if count < limit do
      :ok
    else
      {:error,
       {:rate_limited,
        "You have already posted #{limit} #{subject} in the past hour. Wait a while, then try again."}}
    end
  end

  defp reports_per_hour do
    Application.get_env(:patchbay, :forum_reports_per_hour, @default_reports_per_hour)
  end

  defp replies_per_hour do
    Application.get_env(:patchbay, :forum_replies_per_hour, @default_replies_per_hour)
  end
end
