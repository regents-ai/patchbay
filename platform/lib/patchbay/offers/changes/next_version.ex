defmodule Patchbay.Offers.Changes.NextVersion do
  @moduledoc """
  Numbers a new wording one past the saved Offer's latest, under a lock on
  the saved Offer so two saves at once cannot take the same number.

  Under the same lock it checks that the saved Offer is the actor's and is
  not archived. It then takes the lock on the words themselves
  (`Patchbay.Offers.OfferText`) and refuses words an admin has blocked,
  under any saved Offer; a block of the same words waits for this save.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Offers.Creative
  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.OfferText

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &number(&1, context.actor))
  end

  defp number(changeset, actor) do
    creative_id = Ash.Changeset.get_attribute(changeset, :creative_id)
    text_sha256 = Ash.Changeset.get_attribute(changeset, :text_sha256)

    # The saved Offer and its versions are read here only to number and
    # check this save; nothing is returned to the caller.
    creative =
      Creative
      |> Ash.Query.filter(id == ^creative_id)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read_one!(authorize?: false)

    cond do
      is_nil(creative) or is_nil(actor) or creative.owner_profile_id != actor.id ->
        refuse(changeset, :creative_id, "is not one of your saved Offers")

      creative.archived_at ->
        refuse(changeset, :creative_id, "is archived")

      blocked?(text_sha256) ->
        refuse(changeset, :text, "was blocked by Patchbay")

      true ->
        latest =
          CreativeVersion
          |> Ash.Query.filter(creative_id == ^creative_id)
          |> Ash.max!(:version, authorize?: false)

        Ash.Changeset.force_change_attribute(changeset, :version, (latest || 0) + 1)
    end
  end

  # The words' row is kept and locked until this save commits. Blocks are
  # matched across every advertiser, whose rows the actor cannot read; only
  # the yes or no leaves here.
  defp blocked?(text_sha256) do
    OfferText
    |> Ash.Changeset.for_create(:claim, %{text_sha256: text_sha256}, authorize?: false)
    |> Ash.create!(upsert?: true)
    |> Map.fetch!(:blocked_at)
    |> is_struct(DateTime)
  end

  defp refuse(changeset, field, message) do
    Ash.Changeset.add_error(changeset, InvalidArgument.exception(field: field, message: message))
  end
end
