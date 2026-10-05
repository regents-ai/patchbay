defmodule Patchbay.Offers.Validations.NoteSize do
  @moduledoc "A report's note is at most 2,000 Unicode code points and 8 KiB."

  use Ash.Resource.Validation

  @max_code_points 2_000
  @max_bytes 8_192

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :note) do
      note when is_binary(note) and byte_size(note) > @max_bytes ->
        {:error, field: :note, message: "is longer than 8 KiB"}

      note when is_binary(note) ->
        if length(String.codepoints(note)) > @max_code_points,
          do: {:error, field: :note, message: "is longer than 2,000 characters"},
          else: :ok

      nil ->
        :ok
    end
  end
end
