defmodule Patchbay.DatabaseBusy do
  @moduledoc """
  Whether a read failed because the database was too busy to answer: no
  connection came free in time (`:no_connection`), or PostgreSQL stopped the
  statement at its time limit (`:timeout`, query_canceled, SQLSTATE 57014).
  Any other error is a fault and is never busy.
  """

  @doc """
  The kind of busy an error from a read is, or nil for a fault. Ash keeps a
  database error raised during a read only in its printed form, inside its own
  error classes, so for an Ash read the printed form is what is read; a read
  made without Ash raises the database error itself.
  """
  @spec kind(term()) :: :no_connection | :timeout | nil
  def kind(%DBConnection.ConnectionError{}), do: :no_connection
  def kind(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: :timeout
  def kind(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &kind/1)
  def kind(%{error: "** (DBConnection.ConnectionError) " <> _said}), do: :no_connection

  def kind(%{error: "** (Postgrex.Error) ERROR 57014 (query_canceled)" <> _said}), do: :timeout

  def kind(_error), do: nil

  @doc """
  Whether an error as ErrorTracker records it, by the name of its exception
  and its printed message, is a busy read (`kind/1`): the error itself, or an
  Ash error that printed one inside it.
  """
  @spec recorded?(String.t(), String.t()) :: boolean()
  def recorded?("Elixir.DBConnection.ConnectionError", _message), do: true
  def recorded?("Elixir.Postgrex.Error", "ERROR 57014 (query_canceled)" <> _said), do: true

  def recorded?("Elixir.Ash.Error." <> _class, message),
    do:
      String.contains?(message, [
        "** (DBConnection.ConnectionError) ",
        "** (Postgrex.Error) ERROR 57014 (query_canceled)"
      ])

  def recorded?(_exception, _message), do: false

  @retry_after_seconds 2

  @doc "Seconds to wait before asking again."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: @retry_after_seconds

  @doc "Seconds to wait before asking again, as a Retry-After header says it."
  @spec retry_after() :: String.t()
  def retry_after, do: Integer.to_string(@retry_after_seconds)
end
