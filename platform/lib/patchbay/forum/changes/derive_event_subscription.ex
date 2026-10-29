defmodule Patchbay.Forum.Changes.DeriveEventSubscription do
  @moduledoc """
  Fills in what a subscription is from who asks for it, never from what the
  caller sends: the id (`Regent.MCPEvents.subscription_id/4` over the
  actor's identity, the event, its filter and the callback address), the
  account whose share it counts against, when it runs out, and the sealed
  signing secret.

  The identity of an OAuth connection includes its client, so another
  connected app can neither refresh nor end that connection's subscription.
  A subscription lives a day unless the subscriber asks for less, and never
  past the OAuth token it was made with. A callback address that is not one
  Patchbay may post to is refused as a callback error.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.EventSecret
  alias Patchbay.Forum.EventSubscriptionRefused
  alias Patchbay.Forum.Principal

  @lifetime_ms 86_400_000

  @impl true
  # A subscription whose event, filter or secret is refused is not derived.
  def change(%{valid?: false} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, %{actor: %module{} = actor})
      when module in [Patchbay.Agents.Actor, Patchbay.OAuth.Actor] do
    name = Ash.Changeset.get_attribute(changeset, :name)
    arguments = Ash.Changeset.get_attribute(changeset, :arguments)
    url = Ash.Changeset.get_attribute(changeset, :url)

    case Regent.MCPEvents.subscription_id(identity_owner(actor), name, arguments, url) do
      {:ok, id} -> derive(changeset, id, actor)
      {:error, reason} -> refuse(changeset, reason)
    end
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, "event authority required")

  defp derive(changeset, id, actor) do
    now = DateTime.utc_now()
    ttl_ms = min(Ash.Changeset.get_argument(changeset, :ttl_ms) || @lifetime_ms, @lifetime_ms)

    changeset
    |> Ash.Changeset.force_change_attributes(%{
      id: id,
      owner_id: Principal.for_profile(actor.beneficiary_profile_id),
      expires_at: expiry(actor, DateTime.add(now, ttl_ms, :millisecond)),
      verified_at: now
    })
    |> seal(Ash.Changeset.get_argument(changeset, :secret))
  end

  # A missing secret is already the argument's own error.
  defp seal(changeset, secret) when is_binary(secret),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :secret_ciphertext,
        EventSecret.seal(secret)
      )

  defp seal(changeset, _missing), do: changeset

  defp refuse(changeset, reason),
    do:
      Ash.Changeset.add_error(
        changeset,
        EventSubscriptionRefused.exception(reason: {:callback, reason})
      )

  @doc "The identity a subscription id is derived from for `actor`."
  @spec identity_owner(struct()) :: String.t()
  def identity_owner(%Patchbay.OAuth.Actor{} = actor),
    do: Patchbay.OAuth.Actor.identity_owner(actor)

  def identity_owner(actor), do: Principal.for_profile(actor.beneficiary_profile_id)

  defp expiry(%Patchbay.OAuth.Actor{expires_at: expires_at}, requested),
    do: if(DateTime.before?(expires_at, requested), do: expires_at, else: requested)

  defp expiry(_actor, requested), do: requested
end
