defmodule Patchbay.Forum.Changes.WakeEventDelivery do
  @moduledoc """
  Queues the MCP events delivery sweep in the same transaction as an event a
  subscriber can ask for, so the event's webhooks go out as soon as it
  commits and a rolled-back post queues nothing. The sweep is one job at a
  time however many events land; the minute sweep covers an event that lands
  while one is already running.
  """

  use Ash.Resource.Change

  @delivered_kinds [:reply_posted, :solution_marked]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      if event.kind in @delivered_kinds,
        do: AshOban.schedule(Patchbay.Forum.EventSubscription, :deliver)

      {:ok, event}
    end)
  end
end
