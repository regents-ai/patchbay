defmodule Patchbay.Forum.SearchUnavailable do
  @moduledoc """
  A word search that did not answer: no room to read (`Patchbay.Forum.SearchSlots`),
  out of time, or refused by the database. The search page, the forum endpoint
  and the MCP tools all answer it with `words/0` and ask to try again shortly.
  """

  use Splode.Error, fields: [:cause], class: :unknown

  def message(_error), do: words()

  @doc "What the caller is told."
  @spec words() :: String.t()
  def words, do: "Search is busy right now. Nothing was searched."

  @doc "Whether an error from a search is this one."
  @spec in?(term()) :: boolean()
  def in?(%__MODULE__{}), do: true
  def in?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &in?/1)
  def in?(_error), do: false
end
