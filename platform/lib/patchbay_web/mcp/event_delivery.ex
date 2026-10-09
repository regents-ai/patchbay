defmodule PatchbayWeb.MCP.EventDelivery do
  @moduledoc """
  The `:deliver` action of `Patchbay.Forum.EventSubscription`: posts the
  events one subscription is owed, in order, through the shared safe sender
  (`Regent.MCPEvents.deliver/2`). Its Oban job (the `:deliver` trigger) runs
  one at a time per subscription and retries with backoff.

  A subscription is owed the earliest event after its `delivered_seq` that
  its filter matches and that is still published (`Patchbay.Forum.Updates.next/5`),
  read right before each send. Events it is not owed — another kind, another
  thread, a reply moderation took out of view — are stepped over, as the
  polling feed steps over them. An event it is owed is never stepped over:
  a failure that may pass returns an error, so Oban tries the same event
  again; one that will not stops the subscription where it is.

  Each send happens outside any transaction, and the place moves with a
  compare-and-set from the place this run read, so a job run twice cannot
  move it twice. A repeat send carries the same `eventId`, which the
  receiver uses to drop it.

  The webhook carries ids and a link, never board text: what strangers wrote
  is read through `get_thread`, where it is marked as untrusted. `by_you`
  says the event was this connection's own doing, so a subscriber never acts
  on its own reply.
  """

  use Ash.Resource.ManualUpdate

  require Ash.Expr

  alias Patchbay.Forum.EventSecret
  alias Patchbay.Forum.Updates
  alias Patchbay.Forum.UpdatesCursor
  alias PatchbayWeb.ForumAPI.Participation

  # Events sent per run; the trigger's next sweep takes up the rest.
  @batch 50

  # The board's kind for each event name a subscriber can ask for.
  @kinds %{"reply_created" => :reply_posted, "solution_marked" => :solution_marked}

  @impl true
  def update(changeset, _opts, _context), do: deliver(changeset.data, @batch)

  defp deliver(subscription, 0), do: {:ok, subscription}

  defp deliver(subscription, left) do
    head = Updates.head()

    if live?(subscription) and subscription.delivered_seq < head,
      do: step(subscription, next(subscription, head), left),
      else: {:ok, subscription}
  end

  defp step(subscription, {:skip_to, seq}, left) do
    with {:ok, moved} <- advance(subscription, seq), do: deliver(moved, left)
  end

  defp step(subscription, {:event, event, by_you}, left) do
    case Regent.MCPEvents.deliver(
           signing_view(subscription),
           envelope(subscription, event, by_you)
         ) do
      :ok ->
        with {:ok, moved} <- advance(subscription, event.seq), do: deliver(moved, left - 1)

      {:retry, reason} ->
        {:error, reason}

      {:stop, reason} ->
        halt(subscription, reason)
    end
  end

  defp live?(subscription) do
    subscription.active and DateTime.after?(subscription.expires_at, DateTime.utc_now()) and
      is_binary(subscription.pairing_id) and
      RegentAgents.Authority.active_episode?(Patchbay.Repo, subscription.pairing_id)
  end

  # Moves the place only from where this run read it.
  defp advance(subscription, seq) do
    subscription
    |> Ash.Changeset.for_update(:advance, %{delivered_seq: seq}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(delivered_seq == ^subscription.delivered_seq))
    |> Ash.update()
  end

  # A refresh since this run read the row verified the callback again, and wins.
  defp halt(subscription, reason) do
    subscription
    |> Ash.Changeset.for_update(:halt, %{error: reason}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(verified_at == ^subscription.verified_at))
    |> Ash.update()
  end

  @doc "The board kind behind an event name."
  @spec kind(String.t()) :: atom()
  def kind(name), do: Map.fetch!(@kinds, name)

  @doc "The feed scope a subscription's filter names: its threads, or what its owner follows."
  @spec scope(%{owner_id: String.t(), arguments: map()}) :: UpdatesCursor.scope()
  def scope(%{arguments: %{"thread_ids" => ids}}), do: {:threads, ids}
  def scope(%{owner_id: owner_id}), do: {:following, [owner_id]}

  defp next(subscription, head) do
    Updates.next(
      kind(subscription.name),
      [subscription.owner_id],
      scope(subscription),
      subscription.delivered_seq,
      head
    )
  end

  defp signing_view(subscription) do
    %{
      id: subscription.id,
      name: subscription.name,
      url: subscription.url,
      secret: EventSecret.open(subscription.secret_ciphertext),
      previous_secret:
        subscription.previous_secret_ciphertext &&
          EventSecret.open(subscription.previous_secret_ciphertext),
      secret_rotation_expires_at: subscription.secret_rotation_expires_at
    }
  end

  defp envelope(subscription, event, by_you) do
    %{
      "eventId" => event_id(subscription.id, event.id),
      "name" => subscription.name,
      "timestamp" => DateTime.to_iso8601(event.inserted_at),
      "data" => %{
        "thread_id" => event.thread_id,
        "reply_id" => event.resource_id,
        "url" =>
          PatchbayWeb.Endpoint.url() <>
            Participation.thread_url(event.thread_id) <> "#reply-#{event.resource_id}",
        "by_you" => by_you
      },
      "cursor" => UpdatesCursor.encode(event.seq, scope(subscription))
    }
  end

  # One id per event per subscription, the same on every retry, so a
  # receiver can drop repeats without two subscriptions colliding.
  defp event_id(subscription_id, event_id) do
    "evt_" <>
      Base.url_encode64(:crypto.hash(:sha256, subscription_id <> ":" <> event_id),
        padding: false
      )
  end
end
