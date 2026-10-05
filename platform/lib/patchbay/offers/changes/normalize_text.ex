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

  @messages %{
    invalid_utf8: "is not readable text",
    blank: "is empty",
    not_one_line: "must be a single line",
    invisible_or_control: "contains an invisible or control character",
    unusual_space: "contains a space that is not an ordinary space",
    too_long: "is longer than #{CreativeText.max_code_points()} characters",
    too_many_bytes: "is longer than #{CreativeText.max_bytes()} bytes"
  }

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
          InvalidArgument.exception(field: :text, message: Map.fetch!(@messages, reason))
        )
    end
  end
end
