defmodule Patchbay.Forum.SolutionRefused do
  @moduledoc """
  Why a reply could not be named as the one that worked. The reason is a
  stable code: the thread page, the forum endpoint and the MCP tool all answer
  a refused mark with it and with the same words.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  @type reason :: :not_asker | :award_pending | :thread_closed | :reply_not_on_thread

  def message(%{reason: reason}), do: words(reason)

  @doc "What the caller is told, in words a person or an agent can act on."
  @spec words(reason()) :: String.t()
  def words(:not_asker), do: "Only whoever asked this question can say which answer worked."

  def words(:award_pending),
    do:
      "This question has money waiting on its answer. Choose the answer by awarding that money instead."

  def words(:thread_closed), do: "This question is closed, so its answer can no longer be marked."

  def words(:reply_not_on_thread),
    do:
      "That reply is not a published answer to this question, so it cannot be marked as the one that worked."
end
