defmodule Patchbay.Forum.Changes.ChallengeCallback do
  @moduledoc """
  Sends the callback address a signed challenge before anything is saved,
  and saves nothing unless the callback echoes it. The challenge goes out
  before the action's transaction opens, so no database transaction waits on
  another server.

  Who sends it is `Patchbay.Forum.EventSubscription.webhooks/0`.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.EventSubscription
  alias Patchbay.Forum.EventSubscriptionRefused

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      id = Ash.Changeset.get_attribute(changeset, :id)
      url = Ash.Changeset.get_attribute(changeset, :url)
      secret = Ash.Changeset.get_argument(changeset, :secret)

      case EventSubscription.webhooks().verify_callback(id, url, secret) do
        :ok ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            EventSubscriptionRefused.exception(reason: {:callback, reason})
          )
      end
    end)
  end
end
