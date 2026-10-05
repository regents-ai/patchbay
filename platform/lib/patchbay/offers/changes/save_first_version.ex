defmodule Patchbay.Offers.Changes.SaveFirstVersion do
  @moduledoc """
  Saves a new Offer's first wording in the transaction that made it, so a
  saved Offer always has text. A wording that breaks a rule undoes the
  whole save.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    text = Ash.Changeset.get_argument(changeset, :text)

    Ash.Changeset.after_action(changeset, fn _changeset, creative ->
      case Patchbay.Offers.save_creative_version(creative.id, text, actor: context.actor) do
        {:ok, _version} -> {:ok, creative}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
