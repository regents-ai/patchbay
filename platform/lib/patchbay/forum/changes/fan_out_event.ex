defmodule Patchbay.Forum.Changes.FanOutEvent do
  @moduledoc """
  Writes one notification for each principal following the event's thread,
  site or tool, inside the fan-out's own transaction, so the notifications
  and the event's `fanned_out_at` commit together. The actor who caused the
  event is never notified of their own work. Notifications are unique per
  event and recipient, so a repeated run writes the same rows, not new ones.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Forum.Notification
  alias Patchbay.Forum.Subscription

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      event
      |> recipients()
      |> Enum.map(&%{event_id: event.id, recipient: &1})
      # The job's own write: it answers to nobody's request, and nothing
      # public may deliver a notification.
      |> Ash.bulk_create!(Notification, :deliver, authorize?: false, stop_on_error?: true)

      {:ok, event}
    end)
  end

  defp recipients(event) do
    Subscription
    |> Ash.Query.filter(
      (scope_kind == :thread and scope_id == ^event.thread_id) or
        (scope_kind == :site and scope_id == ^event.site_id)
    )
    # Follows are closed to everyone but their owner; the job reads them all.
    |> Ash.read!(authorize?: false)
    |> Kernel.++(tool_followers(event))
    |> Enum.map(& &1.principal)
    |> Kernel.--([event.actor_principal])
    |> Enum.uniq()
  end

  defp tool_followers(%{tool_id: nil}), do: []

  defp tool_followers(%{tool_id: tool_id}) do
    Subscription
    |> Ash.Query.filter(scope_kind == :tool and scope_id == ^tool_id)
    # Follows are closed to everyone but their owner; the job reads them all.
    |> Ash.read!(authorize?: false)
  end
end
