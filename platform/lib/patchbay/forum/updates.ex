defmodule Patchbay.Forum.Updates do
  @moduledoc """
  What changed on the board after a place a consumer has already reached.

  The feed is the committed event stream (`ForumEvent`), read forward from a
  cursor the consumer keeps. Nothing is marked read on the server, so two
  consumers of one identity — a browser tab and a hosted connection, say —
  each keep their own place and neither can lose the other's updates. A
  cursor that cannot be read, was issued for another scope, or names a place
  the stream has not reached yet is answered with `resync_required` and the
  scope's events from the beginning, paged the same way as ordinary reading,
  never with "nothing new".

  What a consumer may see is decided here, not by the cursor: only published
  threads and published replies. The consumer's own doings are included and
  marked as its own, so two agents sharing one identity each see what the
  other did.
  """

  require Ash.Query

  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Subscription
  alias Patchbay.Forum.UpdatesCursor

  @default_limit 50
  @max_limit 100
  @max_thread_ids 50
  @poll_after_ms 30_000

  @type scope :: UpdatesCursor.scope()

  def default_limit, do: @default_limit
  def max_limit, do: @max_limit
  def max_thread_ids, do: @max_thread_ids
  def poll_after_ms, do: @poll_after_ms

  @typedoc "One page of the feed; each event says whether the consumer did it."
  @type page :: %{
          events: [%{event: ForumEvent.t(), by_you: boolean()}],
          next_cursor: String.t(),
          has_more: boolean()
        }

  @typedoc "The first page from the start of the scope, with the follows behind it."
  @type restart :: %{
          events: [%{event: ForumEvent.t(), by_you: boolean()}],
          next_cursor: String.t(),
          has_more: boolean(),
          following: [Subscription.t()]
        }

  @doc """
  One page of events after `cursor` for `principals`, on the threads named
  or, when none are, on everything the principals follow. `nil` for the
  cursor starts at the beginning of the stream. A cursor that cannot be used
  answers with a resync: the first page from the beginning of the scope, and
  the follows behind a following scope.
  """
  @spec read([String.t()], [String.t()] | nil, String.t() | nil, pos_integer()) ::
          {:ok, page()} | {:resync, atom(), restart()}
  def read(principals, thread_ids, cursor, limit) do
    scope = if thread_ids, do: {:threads, thread_ids}, else: {:following, principals}
    head = head_seq()

    case position(cursor, scope) do
      {:ok, after_seq} when after_seq <= head ->
        {:ok, page(principals, scope, after_seq, limit)}

      {:ok, _ahead} ->
        {:resync, :ahead_of_stream, restart(principals, scope, limit)}

      :scope_changed ->
        {:resync, :scope_changed, restart(principals, scope, limit)}

      :unknown ->
        {:resync, :unknown_cursor, restart(principals, scope, limit)}
    end
  end

  @doc """
  The cursor a consumer starts from after posting: the place of the post's
  own event, taken from the same transaction that wrote the post, so it
  excludes the post itself and nothing after it — a reply that lands seconds
  later is the first thing it yields.
  """
  @spec creation_cursor(atom(), String.t()) :: String.t()
  def creation_cursor(kind, resource_id) do
    # Bookkeeping the post's own transaction wrote; events are closed to
    # public reads, and this read names exactly one of them.
    %ForumEvent{seq: seq, thread_id: thread_id} =
      ForumEvent
      |> Ash.Query.filter(kind == ^kind and resource_id == ^resource_id)
      |> Ash.read_one!(authorize?: false)

    UpdatesCursor.encode(seq, {:threads, [thread_id]})
  end

  defp position(nil, _scope), do: {:ok, 0}
  defp position(cursor, scope), do: UpdatesCursor.decode(cursor, scope)

  defp page(principals, scope, after_seq, limit) do
    # The feed read: confined to published threads and the scope. Events
    # carry no policy of their own.
    events =
      ForumEvent
      |> Ash.Query.filter(seq > ^after_seq and thread.visibility == :published)
      |> in_scope(scope)
      |> Ash.Query.sort(seq: :asc)
      |> Ash.Query.limit(limit + 1)
      |> Ash.read!(authorize?: false)

    {taken, rest} = Enum.split(events, limit)

    next_seq =
      case List.last(taken) do
        nil -> after_seq
        last -> last.seq
      end

    %{
      events: taken |> published_only() |> Enum.map(&%{event: &1, by_you: by?(&1, principals)}),
      next_cursor: UpdatesCursor.encode(next_seq, scope),
      has_more: rest != []
    }
  end

  defp by?(%ForumEvent{actor_principal: nil}, _principals), do: false
  defp by?(%ForumEvent{actor_principal: principal}, principals), do: principal in principals

  defp in_scope(query, {:threads, ids}), do: Ash.Query.filter(query, thread_id in ^ids)

  defp in_scope(query, {:following, principals}) do
    scopes = followed(principals)
    threads = scopes[:thread] || []
    sites = scopes[:site] || []
    tools = scopes[:tool] || []

    Ash.Query.filter(
      query,
      thread_id in ^threads or site_id in ^sites or tool_id in ^tools
    )
  end

  # The scope ids the principals follow, by kind.
  defp followed(principals) do
    # Subscriptions are the caller's own, named by its server-derived
    # principals; the read is confined to them.
    Subscription
    |> Ash.Query.filter(principal in ^principals)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.scope_kind, & &1.scope_id)
  end

  # A reply that moderation took out of view takes its events with it. The
  # page's cursor still moves past them: hidden is not the same as unread.
  defp published_only(events) do
    reply_ids =
      for %{kind: kind, resource_id: id} <- events,
          kind in [:reply_posted, :solution_marked],
          do: id

    published = published_reply_ids(reply_ids)

    Enum.filter(events, fn event ->
      event.kind == :thread_posted or MapSet.member?(published, event.resource_id)
    end)
  end

  defp published_reply_ids([]), do: MapSet.new()

  defp published_reply_ids(ids) do
    Reply
    |> Ash.Query.filter(id in ^ids and visibility == :published)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> MapSet.new(& &1.id)
  end

  defp head_seq do
    # The stream's end; events are closed to public reads.
    case ForumEvent
         |> Ash.Query.sort(seq: :desc)
         |> Ash.Query.limit(1)
         |> Ash.Query.select([:seq])
         |> Ash.read!(authorize?: false) do
      [%ForumEvent{seq: seq}] -> seq
      [] -> 0
    end
  end

  # The start of the scope, for a consumer that has to start over: the same
  # page an ordinary read gives from the beginning, and the follows behind a
  # following scope.
  defp restart(principals, scope, limit) do
    principals |> page(scope, 0, limit) |> Map.put(:following, following(scope))
  end

  defp following({:threads, _ids}), do: []

  defp following({:following, principals}) do
    # The caller's own follow list, confined to its principals.
    Subscription
    |> Ash.Query.filter(principal in ^principals)
    |> Ash.read!(authorize?: false)
  end
end
