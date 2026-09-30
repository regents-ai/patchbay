defmodule Patchbay.Forum.Validations.LikedReplyOnThread do
  @moduledoc """
  A like on a reply must name a published reply on the thread the like names,
  so a like can never be counted on one thread for a post on another.
  """

  use Ash.Resource.Validation

  alias Patchbay.Forum

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :reply_id) do
      nil -> :ok
      reply_id -> on_thread(reply_id, Ash.Changeset.get_attribute(changeset, :report_id))
    end
  end

  defp on_thread(reply_id, report_id) do
    case Forum.get_reply(reply_id) do
      {:ok, %{report_id: ^report_id, visibility: :published}} -> :ok
      _other -> {:error, field: :reply_id, message: "is not a reply on this thread"}
    end
  end

  @impl true
  def describe(_opts), do: [message: "is not a reply on this thread", vars: []]
end
