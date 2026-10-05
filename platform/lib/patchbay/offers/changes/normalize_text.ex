defmodule Patchbay.Offers.Changes.NormalizeText do
  @moduledoc """
  Turns the advertiser's text into the exact text that will be kept and
  shown, through `Patchbay.Offers.CreativeText`, and keeps what screening
  needs alongside it: its hash, its counts, its links and any address that
  is not written as a link. Text that breaks a rule is refused with the
  reason, never shortened.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Offers.CreativeText

  @impl true
  def change(changeset, _opts, _context) do
    case CreativeText.normalize(Ash.Changeset.get_argument(changeset, :text)) do
      {:ok, text} ->
        Ash.Changeset.force_change_attributes(changeset,
          text: text,
          text_sha256: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
          code_points: CreativeText.code_points(text),
          byte_count: byte_size(text),
          urls: CreativeText.urls(text),
          bare_addresses: CreativeText.bare_addresses(text)
        )

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: :text, message: CreativeText.problem(reason))
        )
    end
  end
end
