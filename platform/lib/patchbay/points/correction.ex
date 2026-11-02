defmodule Patchbay.Points.Correction do
  @moduledoc """
  Gives back the Points a report or reply earned once moderation has held it
  back or taken it down (`Patchbay.Points.Hidden` queues it). Each award the
  post earned is corrected by its full amount, under one key however often
  this runs, and the daily allowance it used stays used. A post shown again
  before this runs keeps its points; one shown again after stays corrected.

  While Points is checking the post for any of its rules, this waits: that
  check may have read the post before moderation's word and record an award
  after this looked. A check that starts later reads the post hidden and
  records nothing, and one that finished has recorded its award, so the
  awards are read only once no check is running. An award Points is still
  giving is waited for too.
  """

  use Oban.Worker,
    queue: :points,
    max_attempts: 20,
    unique: [keys: [:kind, :id], period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias Patchbay.Points.Post

  @system %{role: :system}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "id" => id}}) do
    case Post.published?(kind, id) do
      true -> :ok
      false -> correct(kind, id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp correct(kind, id) do
    if checking?(kind, id), do: {:error, :post_being_checked}, else: give_back(events(kind, id))
  end

  defp give_back(events) do
    if Enum.any?(events, &(&1.processing_status == :pending)),
      do: {:error, :award_being_given},
      else: Enum.each(awards(events), &give_back!/1)
  end

  defp events(kind, id) do
    query =
      Ash.Query.filter(
        RegentPoints.Event,
        source_app == ^Patchbay.Points.app() and source_kind == ^kind and
          source_event_key == ^id
      )

    RegentPoints.read_events!(query: query, actor: @system)
  end

  defp awards([]), do: []

  defp awards(events) do
    ids = Enum.map(events, & &1.id)

    query =
      Ash.Query.filter(
        RegentPoints.Entry,
        event_id in ^ids and is_nil(reversal_of_entry_id) and points_micro_delta > 0
      )

    RegentPoints.read_entries!(query: query, actor: @system)
  end

  defp give_back!(award) do
    RegentPoints.reverse!(award.id, "moderation", award.points_micro_delta, "post_hidden",
      actor: @system
    )
  end

  # Oban's own record of Points' check of this post, while it runs.
  defp checking?(kind, id) do
    Patchbay.Repo.exists?(
      from(job in Oban.Job,
        where:
          job.worker == "RegentPoints.IntakeWorker" and job.state == "executing" and
            fragment("?->>'source_app'", job.args) == ^Patchbay.Points.app() and
            fragment("?->>'source_kind'", job.args) == ^kind and
            fragment("?->>'source_event_key'", job.args) == ^id
      ),
      prefix: Oban.config().prefix
    )
  end
end
