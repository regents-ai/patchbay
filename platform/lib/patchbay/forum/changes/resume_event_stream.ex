defmodule Patchbay.Forum.Changes.ResumeEventStream do
  @moduledoc """
  Decides, under the account's lock, where a saved subscription stands in
  the event stream.

  Subscribing again with the same event, filter and callback refreshes the
  existing row in place (`:subscribe` is an upsert on the derived id): it
  keeps its place, so a refresh never skips an event still owed, and a
  stopped subscription resumes at the event it stopped on. A refresh that
  brings a new signing secret keeps the old one for five minutes, so a
  webhook in flight while the subscriber switches keys still verifies.

  A new subscription starts where the subscriber's cursor says, or at the
  stream's end when it brings none. A cursor that is not one of ours for
  this filter cannot be replayed from; the start is then the stream's end,
  and the `truncated` metadata says so.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.EventDelivery
  alias Patchbay.Forum.EventSecret
  alias Patchbay.Forum.Updates
  alias Patchbay.Forum.UpdatesCursor

  # How long a replaced signing secret still signs.
  @rotation_ms 300_000

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      id = Ash.Changeset.get_attribute(changeset, :id)

      # The id is derived from this actor, so it names only its own row; the
      # save itself is authorized.
      {:ok, existing} =
        Patchbay.Forum.get_event_subscription(id, authorize?: false, not_found_error?: false)

      place(changeset, existing)
    end)
    |> Ash.Changeset.after_action(fn changeset, subscription ->
      {:ok,
       Ash.Resource.put_metadata(
         subscription,
         :truncated,
         changeset.context[:event_stream_truncated] == true
       )}
    end)
  end

  defp place(changeset, nil) do
    {start, truncated} = start(changeset)

    changeset
    |> Ash.Changeset.force_change_attribute(:delivered_seq, start)
    |> Ash.Changeset.set_context(%{event_stream_truncated: truncated})
  end

  defp place(changeset, existing) do
    sealed = Ash.Changeset.get_attribute(changeset, :secret_ciphertext)

    keys =
      if EventSecret.open(sealed) == EventSecret.open(existing.secret_ciphertext),
        do: %{
          secret_ciphertext: existing.secret_ciphertext,
          previous_secret_ciphertext: existing.previous_secret_ciphertext,
          secret_rotation_expires_at: existing.secret_rotation_expires_at
        },
        else: %{
          secret_ciphertext: sealed,
          previous_secret_ciphertext: existing.secret_ciphertext,
          secret_rotation_expires_at: DateTime.add(DateTime.utc_now(), @rotation_ms, :millisecond)
        }

    changeset
    |> Ash.Changeset.force_change_attributes(Map.merge(keys, %{active: true, last_error: nil}))
    |> Ash.Changeset.set_context(%{event_stream_truncated: false})
  end

  defp start(changeset) do
    head = Updates.head()

    scope =
      EventDelivery.scope(%{
        owner_id: Ash.Changeset.get_attribute(changeset, :owner_id),
        arguments: Ash.Changeset.get_attribute(changeset, :arguments)
      })

    case Ash.Changeset.get_argument(changeset, :cursor) do
      nil ->
        {head, false}

      cursor ->
        case UpdatesCursor.decode(cursor, scope) do
          {:ok, seq} when seq <= head -> {seq, false}
          _unusable -> {head, true}
        end
    end
  end
end
