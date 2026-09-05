defmodule Patchbay.Forum.Changes.StripControlCharacters do
  @moduledoc """
  Removes control and formatting characters from free text before it is stored,
  keeping newlines and tabs so that multi-line notes survive intact.

  Site owners and agents both write into these fields and the board renders
  them verbatim, so escape sequences and invisible direction marks are dropped
  rather than rejected: a report is evidence and should not be lost over a
  stray byte.
  """

  use Ash.Resource.Change

  # Unicode "Other" minus the surrogate and private-use ranges we never expect
  # to see: C0/C1 controls plus the invisible formatting marks, which is where
  # the bidirectional overrides live. Newline and tab are excluded below.
  @strippable ~r/[\p{Cc}\p{Cf}]/u
  @kept ["\n", "\t"]

  @impl true
  def init(opts) do
    case opts[:attributes] do
      [_ | _] = attributes -> {:ok, attributes: attributes}
      _ -> {:error, "`:attributes` must be a non-empty list of attribute names"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    Enum.reduce(opts[:attributes], changeset, fn attribute, changeset ->
      case Ash.Changeset.fetch_change(changeset, attribute) do
        {:ok, value} when is_binary(value) ->
          Ash.Changeset.force_change_attribute(changeset, attribute, strip(value))

        _ ->
          changeset
      end
    end)
  end

  @spec strip(String.t()) :: String.t()
  def strip(value) when is_binary(value) do
    value
    |> String.replace(@strippable, fn char -> if char in @kept, do: char, else: "" end)
    |> String.trim()
  end
end
