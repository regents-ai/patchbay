defmodule Patchbay.ErrorIgnorer do
  @moduledoc """
  Leaves out an exception the site answers below 500, such as not found or a bad
  request. Anyone can raise those by visiting a wrong address, so saving them
  would let anyone fill the table. Server faults, exits and throws are all kept.

  A read the database was too busy to answer is left out too
  (`Patchbay.DatabaseBusy`): the site answers it 503 and logs it, and saving it
  would add a write to a database that is already full.

  A job attempt that Oban will retry is left out too: ErrorTracker reports each
  failed attempt with Oban's `state`, which is `:failure` while attempts remain
  and `:discard` on the last one. A job that recovers on a later attempt saves
  nothing, and one that runs out of attempts is saved once.
  """

  @behaviour ErrorTracker.Ignorer

  alias Patchbay.DatabaseBusy

  @impl ErrorTracker.Ignorer
  def ignore?(_error, %{state: :failure}), do: true

  def ignore?(%ErrorTracker.Error{kind: "Elixir." <> _module = kind, reason: reason}, _context),
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
end
