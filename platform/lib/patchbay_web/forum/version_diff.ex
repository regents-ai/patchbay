defmodule PatchbayWeb.Forum.VersionDiff do
  @moduledoc """
  What changed between one version of a tool and the one before it.

  A tool's history reads like a log of edits, so each version is shown against
  its predecessor: the title it was given, and the sentences of its description
  that were added or dropped. Only what the board actually keeps about a
  version is compared — its name, its fingerprint, its title and its
  description — so nothing here is guessed from anything the board never saw.

  This is a pure comparison of two rows the caller already has. It reads
  nothing, so a page that has loaded a tool's versions can show the whole
  history without asking for anything else.
  """

  alias Patchbay.Forum.Tool

  @type sentence :: {:kept | :added | :removed, String.t()}

  @type t :: %__MODULE__{
          title_before: String.t() | nil,
          title_after: String.t() | nil,
          title_changed?: boolean(),
          sentences: [sentence()],
          description_changed?: boolean(),
          changed?: boolean()
        }

  defstruct title_before: nil,
            title_after: nil,
            title_changed?: false,
            sentences: [],
            description_changed?: false,
            changed?: false

  @doc """
  Each version paired with the change that produced it, newest first.

  The last version in the list has nothing before it on the page, so it is
  paired with `nil`: there is no earlier wording to compare it against.
  """
  @spec version_changes([Tool.t()]) :: [{Tool.t(), t() | nil}]
  def version_changes([]), do: []

  def version_changes(versions) do
    predecessors = Enum.drop(versions, 1) ++ [nil]

    Enum.zip_with(versions, predecessors, fn
      version, nil -> {version, nil}
      version, older -> {version, between(older, version)}
    end)
  end

  @doc "How the wording moved from one version to the next."
  @spec between(Tool.t(), Tool.t()) :: t()
  def between(%Tool{} = before, %Tool{} = aft) do
    sentences = sentence_diff(sentences(before.description), sentences(aft.description))
    title_changed? = before.title != aft.title
    description_changed? = Enum.any?(sentences, fn {kind, _text} -> kind != :kept end)

    %__MODULE__{
      title_before: before.title,
      title_after: aft.title,
      title_changed?: title_changed?,
      sentences: sentences,
      description_changed?: description_changed?,
      changed?: title_changed? or description_changed?
    }
  end

  # Sentences are the unit a reader compares, so a description is cut at the
  # end of one and the pieces are matched up whole.
  @sentence_break ~r/(?<=[.!?])\s+/

  defp sentences(nil), do: []

  defp sentences(text) when is_binary(text) do
    text
    |> String.split(@sentence_break)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sentence_diff(before, aft) do
    before
    |> List.myers_difference(aft)
    |> Enum.flat_map(fn
      {:eq, kept} -> Enum.map(kept, &{:kept, &1})
      {:del, removed} -> Enum.map(removed, &{:removed, &1})
      {:ins, added} -> Enum.map(added, &{:added, &1})
    end)
  end
end
