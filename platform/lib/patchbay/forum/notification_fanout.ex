defmodule Patchbay.Forum.NotificationFanout do
  @moduledoc """
  Delivers board events to the principals who subscribed for them.

  A GenServer wakes on a short interval and works the event table itself —
  durable records, not a cursor — so a restart or a crash mid-run loses
  nothing: an event stays unfanned until every matching subscription has its
  notification row, and a retried event delivers the same notification again
  by uniqueness, not a second one. The actor who caused an event is never
  notified of their own work.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Notification
  alias Patchbay.Forum.Subscription

  @interval_ms 2_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :fanout, @interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:fanout, state) do
    process_events()
    Process.send_after(self(), :fanout, @interval_ms)
    {:noreply, state}
  end

  @doc """
  Delivers every event still awaiting fan-out. Called by the worker's timer;
  also callable directly so a test (or an operator console) can run one pass.
  """
  @spec process_events() :: non_neg_integer()
  def process_events do
    # Internal reads and writes: the worker answers to nobody's request.
    ForumEvent
    |> Ash.Query.filter(is_nil(fanned_out_at))
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(200)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn event, delivered -> delivered + deliver(event) end)
  end

  defp deliver(event) do
    # Internal reads and writes: the worker answers to nobody's request, and
    # the records it touches are closed to the public.
    recipients =
      [
        Subscription
        |> Ash.Query.filter(
          (scope_kind == :thread and scope_id == ^event.thread_id) or
            (scope_kind == :site and scope_id == ^event.site_id)
        )
        |> Ash.read!(authorize?: false),
        if event.tool_id do
          Subscription
          |> Ash.Query.filter(scope_kind == :tool and scope_id == ^event.tool_id)
          |> Ash.read!(authorize?: false)
        else
          []
        end
      ]
      |> List.flatten()
      |> Enum.map(& &1.principal)
      |> Kernel.--([event.actor_principal])
      |> Enum.uniq()

    # Deliveries and the event's own receipt are the worker's internal writes.
    delivered =
      Enum.count(recipients, fn recipient ->
        match?(
          {:ok, _},
          Ash.create(
            Ash.Changeset.for_create(Notification, :deliver, %{
              event_id: event.id,
              recipient: recipient
            }),
            authorize?: false
          )
        )
      end)

    Ash.update!(event, %{}, action: :mark_fanned_out, authorize?: false)
    delivered
  end

  defp enabled? do
    Application.get_env(:patchbay, :notification_fanout, true)
  end
end
