defmodule Patchbay.Points.TakeBack do
  @moduledoc """
  Takes back what a post earned once moderation hid it or set it aside
  (`Patchbay.Points.Award`), with Regent Points' own correction
  (`RegentPoints.reverse/5`): the post's award under its rule is corrected to
  nothing.

  Moderation queues it in its own transaction, so a moderation that is saved
  always has its job, and moderation never waits on Points or is refused
  because Points cannot be reached. Until earning has ever started nothing can
  have been awarded, so nothing is queued.

  One job for each post and rule while it waits or runs, so moderation's
  further words on the post in that time add nothing. Every take-back of an
  award uses one correction key, so a later job for the same post, or the same
  job run again, takes nothing more. A post that earned nothing takes nothing.

  Points asks about the post again when it awards it, so a post moderated
  before then earns nothing. An award Points is still deciding is waited for:
  it may have asked just before moderation's word, so the job tries again until
  Points has decided, and takes back what it then awarded.

  A failure is tried again, up to 20 attempts, and each one is kept on the
  job; after the last, Oban discards it and the error tracker at /admin/errors
  shows it (`Patchbay.SavedErrors`).
  """

  use Oban.Worker,
    queue: :points,
    max_attempts: 20,
    unique: [
      keys: [:rule_id, :source_kind, :source_event_key],
      period: :infinity,
      states: :incomplete
    ]

  require Ash.Query

  alias RegentPoints.Entry
  alias RegentPoints.Event
  alias RegentPoints.Rules
  alias RegentPoints.Store

  @doc "Queues taking back what Patchbay's `kind` `id` earned under `rule`, in the caller's transaction."
  @spec queue(String.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def queue(rule, kind, id) do
    if Keyword.get(Rules.config(), :starts_at) do
      with {:ok, _job} <-
             Oban.insert(new(%{rule_id: rule, source_kind: kind, source_event_key: id})),
           do: :ok
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"rule_id" => rule, "source_kind" => kind, "source_event_key" => id}
      }) do
    program = Rules.program()

    events =
      Ash.Query.filter(
        Event,
        program_id == ^program and rule_id == ^rule and source_app == "patchbay" and
          source_kind == ^kind and source_event_key == ^id
      )

    with {:ok, [event]} <- RegentPoints.read_events(query: events, actor: Store.system()),
         :ok <- decided(event),
         awards =
           Ash.Query.filter(Entry, program_id == ^program and award_key == ^event.award_key),
         {:ok, [%{points_micro_delta: points} = award]} when points > 0 <-
           RegentPoints.read_entries(query: awards, actor: Store.system()),
         {:ok, _correction} <-
           RegentPoints.reverse(award.id, "moderation", points, "moderated",
             actor: Store.system()
           ) do
      :ok
    else
      {:ok, _nothing_earned} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # An award still being written may have asked about the post before moderation
  # changed it: the job tries again once Points has decided.
  defp decided(%{processing_status: :pending}), do: {:error, :award_not_decided}
  defp decided(_event), do: :ok
end
