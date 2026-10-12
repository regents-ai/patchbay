defmodule Patchbay.Offers.Saving do
  @moduledoc """
  The work behind the `:save` actions of `Patchbay.Offers.Creative` and
  `Patchbay.Offers.CreativeVersion`, inside their transaction.

  Every save carries the request key its form or agent made for it. The
  account's row is locked first, the same lock that orders the account's
  saves for the daily limit (`Patchbay.Offers.Changes.DailyOfferLimit`), so
  a save already made with the key has committed by the time it is looked
  for. A key used before answers with what it saved then: nothing new is
  written or screened, and no daily save is used.
  """

  require Ash.Query

  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers.Creative
  alias Patchbay.Offers.CreativeVersion

  @doc "Saves a new Offer for `actor`, or answers with the Offer its request key saved."
  def offer(args, actor) do
    lock_account(actor)

    # Part of the action that asked, whose policy already decided.
    Creative
    |> Ash.Query.filter(owner_profile_id == ^actor.id and request_key == ^args.request_key)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        Creative
        |> Ash.Changeset.for_create(:create, args, actor: actor)
        |> Ash.create()

      creative ->
        {:ok, creative}
    end
  end

  @doc "Saves a new wording for `actor`, or answers with the wording its request key saved."
  def wording(args, actor) do
    lock_account(actor)

    # Part of the action that asked, whose policy already decided. Only the
    # actor's own Offer is looked in; any other is refused by the write.
    CreativeVersion
    |> Ash.Query.filter(
      creative_id == ^args.creative_id and request_key == ^args.request_key and
        creative.owner_profile_id == ^actor.id
    )
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        CreativeVersion
        |> Ash.Changeset.for_create(:write, args, actor: actor)
        |> Ash.create()

      version ->
        {:ok, version}
    end
  end

  # Only takes the lock; no profile is returned to anyone.
  defp lock_account(actor) do
    AgentProfile
    |> Ash.Query.filter(id == ^actor.id)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one!(authorize?: false)
  end
end
