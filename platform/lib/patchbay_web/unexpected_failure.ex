defmodule PatchbayWeb.UnexpectedFailure do
  @moduledoc """
  Logs a failure the site answers only with "try again", with the request it
  ended, so a fault the caller sees as a plain 503 still leaves a trace.
  """

  require Logger

  @doc "Logs `error` against `conn`'s request and returns `conn`."
  def log(conn, error) do
    Logger.error("#{conn.method} #{conn.request_path} answered try again: #{describe(error)}")
    conn
  end

  # One line: the log feed keeps only an error's first line, and an Ash error
  # names its cause on a later one.
  defp describe(error), do: error |> text() |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()

  defp text(error) when is_exception(error), do: Exception.message(error)
  defp text(error), do: inspect(error)
end
