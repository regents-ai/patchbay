defmodule Patchbay.Forum.Changes.TakeListedSitePicture do
  @moduledoc """
  The work of `Patchbay.Forum.ListedSitePicture`'s `:take`: asks the
  screenshot machine for a picture of the domain's home page
  (`Patchbay.Forum.TakeSitePicture.shoot/1`) and keeps it.

  A page that answers with an error status has given its answer, so that no
  picture came back is kept at once, and the domain is not asked for again.
  Any other picture that does not come back is an error
  (`Patchbay.Forum.PictureNotTaken`), and its job tries again with Oban's
  backoff; on the last try (`last_try?`) that none came back is kept instead.
  """

  use Ash.Resource.Change

  require Logger

  alias Patchbay.Forum.PictureNotTaken
  alias Patchbay.Forum.TakeSitePicture

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &shoot/1)

  defp shoot(changeset) do
    domain = Ash.Changeset.get_attribute(changeset, :domain)

    case TakeSitePicture.shoot("https://" <> domain <> "/") do
      {:ok, image} ->
        taken(changeset, image)

      {:error, {:page_status, _status} = reason} ->
        not_taken(changeset, domain, reason)

      {:error, reason} ->
        if Ash.Changeset.get_argument(changeset, :last_try?),
          do: not_taken(changeset, domain, reason),
          else: try_again(changeset, domain, reason)
    end
  end

  defp taken(changeset, image),
    do:
      Ash.Changeset.force_change_attributes(changeset, image: image, taken_at: DateTime.utc_now())

  defp not_taken(changeset, domain, reason) do
    warn(domain, reason)
    Ash.Changeset.force_change_attributes(changeset, image: nil, taken_at: DateTime.utc_now())
  end

  defp try_again(changeset, domain, reason) do
    warn(domain, reason)
    Ash.Changeset.add_error(changeset, PictureNotTaken.exception(reason: reason))
  end

  # A site that is slow or failing leaves no picture; that is the site's doing,
  # not Patchbay's, so it is a warning that carries why.
  defp warn(domain, reason) do
    Logger.warning("#{domain}: " <> Exception.message(PictureNotTaken.exception(reason: reason)))
  end
end
