defmodule Patchbay.Forum.Actions.UnsubscribeFromEvents do
  @moduledoc """
  Ends the actor's own subscription to one event, filter and callback
  address. The subscription is named by the same derived id `:subscribe`
  makes, so an actor can only ever end its own. Ending one that does not
  exist, or has already gone, succeeds and changes nothing.
  """

  use Ash.Resource.Actions.Implementation

  alias Patchbay.Forum.Changes.DeriveEventSubscription
  alias Patchbay.Forum.EventSubscriptionRefused

  @impl true
  def run(input, _opts, %{actor: actor}) do
    case Regent.MCPEvents.subscription_id(
           DeriveEventSubscription.identity_owner(actor),
           input.arguments.name,
           input.arguments.arguments,
           input.arguments.url
         ) do
      {:ok, id} ->
        remove(id, actor)

      {:error, reason} ->
        {:error, EventSubscriptionRefused.exception(reason: {:callback, reason})}
    end
  end

  defp remove(id, actor) do
    # The id is derived from this actor; the destroy itself is authorized.
    case Patchbay.Forum.get_event_subscription(id, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> :ok
      {:ok, subscription} -> Patchbay.Forum.end_event_subscription(subscription, actor: actor)
      {:error, error} -> {:error, error}
    end
  end
end
