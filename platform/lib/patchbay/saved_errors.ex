defmodule Patchbay.SavedErrors do
  @moduledoc """
  Which failed requests, pages and jobs are saved for the site's admins at
  /admin/errors, what of each is kept, and for how long. ErrorTracker asks
  `ignore?/2` and `sanitize/1` (`config :error_tracker`), and the daily
  schedule runs `perform/1`.

  Only server faults are saved. An exception the site answers below 500, such
  as not found or a bad request, is left out: anyone can raise those by
  visiting a wrong address, so saving them would let anyone fill the table.
  Exits and throws are kept.

  A read the database was too busy to answer (`Patchbay.DatabaseBusy`), from a
  page, a job or a live page, is left out too: saving it would add a write to
  a database that is already full. A page answers it 503 and logs "Page
  unavailable"; a job that runs out of attempts logs its discard.

  A job attempt that Oban will retry is left out: ErrorTracker reports each
  failed attempt with Oban's `state`, which is `:failure` while attempts
  remain and `:discard` on the last one. A job that recovers on a later
  attempt saves nothing, and one that runs out of attempts is saved once.

  Of each fault only where it happened is kept: the request's host, path and
  method, the page, component and event names, and the job's worker, queue
  and attempt. Headers, addresses, query strings, parameters and job
  arguments can carry a signing key, a session or a person's details, so none
  is kept.

  Once a day every occurrence older than a week is cleared, and every error
  not seen for a week, whatever its status. ErrorTracker's own pruner only
  clears resolved errors, so a fault that keeps happening would otherwise
  grow the error tables without end.
  """

  @behaviour ErrorTracker.Ignorer
  @behaviour ErrorTracker.Filter

  use Oban.Worker, queue: :errors, max_attempts: 3

  import Ecto.Query

  alias ErrorTracker.{Error, Occurrence}
  alias Patchbay.DatabaseBusy
  alias Patchbay.Repo

  @kept ~w(
    request.host request.path request.method
    live_view.view live_view.component live_view.event
    job.id job.worker job.queue job.attempt job.priority
  )

  @batch 5_000

  @impl ErrorTracker.Ignorer
  def ignore?(_error, %{state: :failure}), do: true

  def ignore?(%Error{kind: "Elixir." <> _module = kind, reason: reason}, _context),
    do: DatabaseBusy.recorded?(kind, reason) or kind |> String.to_existing_atom() |> visitors?()

  def ignore?(_error, _context), do: false

  # Ash's four error classes take their status from the errors they wrap, so the
  # class names whose doing it was: bad input or a refusal, or a server fault.
  defp visitors?(class) when class in [Ash.Error.Invalid, Ash.Error.Forbidden], do: true
  defp visitors?(class) when class in [Ash.Error.Unknown, Ash.Error.Framework], do: false

  defp visitors?(exception),
    do:
      Code.ensure_loaded?(exception) and function_exported?(exception, :exception, 1) and
        Plug.Exception.status(exception.__struct__()) < 500

  @impl ErrorTracker.Filter
  def sanitize(context), do: Map.take(context, @kept)

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
    delete_all(from(occurrence in Occurrence, where: occurrence.inserted_at < ^cutoff))
    # An error's remaining occurrences go with it.
    delete_all(from(error in Error, where: error.last_occurrence_at < ^cutoff))
    :ok
  end

  # In batches, so one run never holds a long lock on a large table.
  defp delete_all(query) do
    batch = from(row in query, select: row.id, limit: @batch)

    case Repo.delete_all(from(row in query, where: row.id in subquery(batch))) do
      {@batch, _rows} -> delete_all(query)
      {_fewer, _rows} -> :ok
    end
  end
end
