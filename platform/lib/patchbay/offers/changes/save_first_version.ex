defmodule Patchbay.Offers.Changes.SaveFirstVersion do
  @moduledoc """
  Saves a new Offer's first wording in the transaction that made it, so a
  saved Offer always has text. A wording that breaks a rule undoes the
  whole save. The first wording carries the Offer's own request key.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    text = Ash.Changeset.get_argument(changeset, :text)

    Ash.Changeset.after_action(changeset, fn _changeset, creative ->
      creative.id
      |> Patchbay.Offers.save_creative_version(text, creative.request_key, actor: context.actor)
      |> case do
        {:ok, _version} -> {:ok, creative}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
