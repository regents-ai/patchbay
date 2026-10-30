defmodule Patchbay.DatabaseBusy do
  @moduledoc """
  Whether a read failed because the database was too busy to answer: no
  connection came free in time (`:no_connection`), or PostgreSQL stopped the
  statement at its time limit (`:timeout`, query_canceled, SQLSTATE 57014).
  Any other error is a fault and is never busy.
  """

  @doc """
  The kind of busy an error from an Ash read is, or nil for a fault. Ash keeps
  a database error raised during a read only in its printed form, inside its
  own error classes, so the printed form is what is read.
  """
  @spec kind(term()) :: :no_connection | :timeout | nil
  def kind(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &kind/1)
  def kind(%{error: "** (DBConnection.ConnectionError) " <> _said}), do: :no_connection

  def kind(%{error: "** (Postgrex.Error) ERROR 57014 (query_canceled)" <> _said}), do: :timeout

  def kind(_error), do: nil

  @retry_after_seconds 2

  @doc "Seconds to wait before asking again."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: @retry_after_seconds

  @doc "Seconds to wait before asking again, as a Retry-After header says it."
  @spec retry_after() :: String.t()
  def retry_after, do: Integer.to_string(@retry_after_seconds)
end
