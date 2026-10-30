defmodule Patchbay.Forum.SearchUnavailable do
  @moduledoc """
  A text search that did not answer because the site is busy
  (`Patchbay.Forum.SearchSlots`): no place free in time (`cause: :no_slot`), no
  database connection free in time (`:no_connection`), or out of time
  (`:timeout`). The home page, the search window, the forum endpoint and the
  MCP tools all answer it with `words/0` and ask to try again shortly.
  """

  use Splode.Error, fields: [:cause], class: :unknown

  def message(_error), do: words()

  @doc "What the caller is told."
  @spec words() :: String.t()
  def words, do: "Search is busy right now. Nothing was searched."

  @doc "Seconds to wait before searching again, as a Retry-After header says it."
  @spec retry_after() :: String.t()
  def retry_after, do: "2"

  @doc "Whether an error from a search is this one."
  @spec in?(term()) :: boolean()
  def in?(%__MODULE__{}), do: true
  def in?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &in?/1)
  def in?(_error), do: false
end
