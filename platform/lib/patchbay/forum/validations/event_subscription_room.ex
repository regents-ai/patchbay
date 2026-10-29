defmodule Patchbay.Forum.Validations.EventSubscriptionRoom do
  @moduledoc """
  An account holds at most `Patchbay.Forum.EventSubscription.per_account/0`
  live event subscriptions, whichever of its connections made them.

  Refreshing a live one is never refused. A new one, or bringing back one
  that has run out, needs room in the account's share. `:subscribe` looks
  twice: once before the callback is sent anything, and again under the
  account's lock just before the save, so two sent at once at the edge
  cannot both get in.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias Patchbay.Forum.EventSubscription
  alias Patchbay.Forum.EventSubscriptionRefused

  @impl true
  def validate(changeset, _opts, _context) do
    id = Ash.Changeset.get_attribute(changeset, :id)
    owner_id = Ash.Changeset.get_attribute(changeset, :owner_id)

    # Without an id or owner the subscription is already refused for that.
    if is_nil(id) or is_nil(owner_id) or room?(existing(id), owner_id),
      do: :ok,
      else: {:error, EventSubscriptionRefused.exception(reason: :too_many_subscriptions)}
  end

  # The derived id names only this actor's own subscription.
  defp existing(id) do
    {:ok, existing} =
      Patchbay.Forum.get_event_subscription(id, authorize?: false, not_found_error?: false)

    existing
  end

  defp room?(%EventSubscription{expires_at: expires_at}, owner_id),
    do: DateTime.after?(expires_at, DateTime.utc_now()) or room?(nil, owner_id)

  defp room?(nil, owner_id), do: live_count(owner_id) < EventSubscription.per_account()

  # The count covers every connection's subscriptions for the account, which
  # no one actor may read, so it is the server's own count.
  defp live_count(owner_id) do
    EventSubscription
    |> Ash.Query.filter(owner_id == ^owner_id and expires_at > now())
    |> Ash.count!(authorize?: false)
  end
end
