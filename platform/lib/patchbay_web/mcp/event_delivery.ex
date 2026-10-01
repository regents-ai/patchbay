defmodule PatchbayWeb.MCP.EventDelivery do
  @moduledoc """
  Patchbay's storage side of the shared MCP events worker
  (`Regent.MCPEvents.Adapter`): which event each subscription is owed next,
  the lease that fences one attempt at it, and the record of how it went.

  A subscription is owed the earliest event after its `delivered_seq` that
  its filter matches and that is still published (`Patchbay.Forum.Updates.next/5`).
  Events it is not owed — another kind, another thread, a reply moderation
  took out of view — are stepped over, as the polling feed steps over them.
  An event it is owed is never stepped over: a retry or a stop keeps it
  outstanding, and only the callback's acknowledgement moves past it.

  The webhook carries ids and a link, never board text: what strangers wrote
  is read through `get_thread`, where it is marked as untrusted. `by_you`
  says the event was this connection's own doing, so a subscriber never acts
  on its own reply.
  """

  @behaviour Regent.MCPEvents.Adapter

  require Ash.Query

  alias Patchbay.Forum.EventSecret
  alias Patchbay.Forum.EventSubscription
  alias Patchbay.Forum.Updates
  alias Patchbay.Forum.UpdatesCursor
  alias PatchbayWeb.ForumAPI.Participation

  # How many subscriptions one claim looks at before answering :empty.
  @batch 20

  # The board's kind for each event name a subscriber can ask for.
  @kinds %{"reply_created" => :reply_posted, "solution_marked" => :solution_marked}

  @impl true
  def claim_next(now, lease_ms) do
    claimed =
      Ash.transact(EventSubscription, fn ->
        head = Updates.head()
        Enum.find_value(due(now, head), :empty, &claim(&1, head, now, lease_ms))
      end)

    case claimed do
      {:ok, claim} -> claim
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def authorize_delivery(%{subscription: %{id: id}, token: token, event: event}, _now) do
    # The worker's own reload of the row it leased; subscriptions have no
    # public way in.
    case Ash.get(EventSubscription, id, authorize?: false, not_found_error?: false) do
      {:ok, %EventSubscription{lease_token: ^token} = subscription} ->
        if owed?(subscription, event),
          do: {:ok, worker_view(subscription)},
          else: {:error, :no_longer_owed}

      {:ok, _gone_or_released} ->
        {:stop, :unsubscribed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def finish(%{subscription: %{id: id}, token: token}, outcome, _now) do
    {action, input} =
      case outcome do
        {:delivered, _cursor} ->
          {:delivered, %{}}

        {:retry, reason, next_at} ->
          {:retry_later, %{next_attempt_at: next_at, last_error: describe(reason)}}

        {:stop, reason} ->
          {:halt, %{last_error: describe(reason)}}
      end

    # Only the holder of the lease finishes the attempt.
    result =
      EventSubscription
      |> Ash.Query.filter(id == ^id and lease_token == ^token)
      |> Ash.bulk_update(action, input,
        authorize?: false,
        strategy: :atomic,
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: [_finished]} -> :ok
      %Ash.BulkResult{status: :success, records: []} -> {:error, :lease_lost}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc "The board kind behind an event name."
  @spec kind(String.t()) :: atom()
  def kind(name), do: Map.fetch!(@kinds, name)

  @doc "The feed scope a subscription's filter names: its threads, or what its owner follows."
  @spec scope(%{owner_id: String.t(), arguments: map()}) :: UpdatesCursor.scope()
  def scope(%{arguments: %{"thread_ids" => ids}}), do: {:threads, ids}
  def scope(%{owner_id: owner_id}), do: {:following, [owner_id]}

  # Subscriptions with an event possibly owed and no attempt under way or
  # waiting, oldest-touched first; rows another worker holds are passed over.
  defp due(now, head) do
    EventSubscription
    |> Ash.Query.filter(
      active and expires_at > ^now and delivered_seq < ^head and
        (is_nil(lease_expires_at) or lease_expires_at <= ^now) and
        (is_nil(next_attempt_at) or next_attempt_at <= ^now)
    )
    |> Ash.Query.sort(updated_at: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
    |> Ash.read!(authorize?: false)
  end

  defp claim(subscription, head, now, lease_ms) do
    case next(subscription, head) do
      {:skip_to, seq} ->
        # Internal bookkeeping on the row this claim holds locked.
        Ash.update!(subscription, %{delivered_seq: seq}, action: :skip_to, authorize?: false)
        nil

      {:event, event, by_you} ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        # Attempts count per event: the same outstanding event counts on,
        # a new one starts again at one.
        attempt = if subscription.pending_seq == event.seq, do: subscription.attempt + 1, else: 1

        leased =
          Ash.update!(
            subscription,
            %{
              lease_token: token,
              lease_expires_at: DateTime.add(now, lease_ms, :millisecond),
              pending_seq: event.seq,
              attempt: attempt
            },
            action: :lease,
            authorize?: false
          )

        {:ok,
         %{
           token: token,
           subscription: worker_view(leased),
           event: envelope(leased, event, by_you),
           attempt: attempt
         }}
    end
  end

  defp next(subscription, head) do
    Updates.next(
      kind(subscription.name),
      [subscription.owner_id],
      scope(subscription),
      subscription.delivered_seq,
      head
    )
  end

  # Still owed right before sending: published, in the filter, and still the
  # earliest outstanding event. A follow ended or a reply taken out of view
  # since the claim withdraws it.
  defp owed?(subscription, %{"cursor" => cursor}) do
    {:ok, seq} = UpdatesCursor.decode(cursor, scope(subscription))
    match?({:event, %{seq: ^seq}, _by_you}, next(subscription, seq))
  end

  defp worker_view(subscription) do
    %{
      id: subscription.id,
      owner_id: subscription.owner_id,
      name: subscription.name,
      arguments: subscription.arguments,
      url: subscription.url,
      secret: EventSecret.open(subscription.secret_ciphertext),
      previous_secret:
        subscription.previous_secret_ciphertext &&
          EventSecret.open(subscription.previous_secret_ciphertext),
      secret_rotation_expires_at: subscription.secret_rotation_expires_at,
      expires_at: subscription.expires_at,
      active: subscription.active
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

  # Reasons are atoms and status tuples from the worker; they hold no secret.
  defp describe(reason), do: inspect(reason)
end
