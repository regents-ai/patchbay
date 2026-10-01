defmodule Patchbay.Assist.KnownFix do
  @moduledoc """
  One fix Patchbay already knows for getting unstuck on a site, as its
  Markdown file in `priv/known_fixes` writes it.

  A file opens with a short header (`title`, `kind`, `sites`, `tools` and,
  when Patchbay has tried the fix itself, `checked`) between `---` lines,
  then five sections: Applies when, Does not apply when, Steps, Caveats and
  Sources. A `fix` says what to do; a `question` says which one detail the
  agent should find and ask again with.
  """

  @sections %{
    "Applies when" => :applies_when,
    "Does not apply when" => :does_not_apply_when,
    "Steps" => :steps,
    "Caveats" => :caveats,
    "Sources" => :sources
  }

  @enforce_keys [
    :id,
    :title,
    :kind,
    :sites,
    :tools,
    :checked,
    :applies_when,
    :does_not_apply_when,
    :steps,
    :caveats,
    :sources
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          kind: :fix | :question,
          sites: [String.t()],
          tools: String.t(),
          checked: Date.t() | nil,
          applies_when: String.t(),
          does_not_apply_when: String.t(),
          steps: String.t(),
          caveats: String.t(),
          sources: String.t()
        }

  @doc "The fix the file named `id` holds, from its text."
  @spec parse!(String.t(), String.t()) :: t()
  def parse!(id, text) do
    ["", header, body] = String.split(text, ~r/^---$/m, parts: 3)
    fields = header |> String.split("\n", trim: true) |> Map.new(&field!/1)

    sections =
      ~r/^## (.+)$/m
      |> Regex.split(body, include_captures: true, trim: true)
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.chunk_every(2)
      |> Map.new(fn ["## " <> name, content] ->
        {Map.fetch!(@sections, String.trim(name)), String.trim(content)}
      end)

    struct!(
      __MODULE__,
      Map.merge(sections, %{
        id: id,
        title: Map.fetch!(fields, "title"),
        kind: kind!(Map.fetch!(fields, "kind")),
        sites:
          fields
          |> Map.fetch!("sites")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1),
        tools: Map.fetch!(fields, "tools"),
        checked: checked!(fields["checked"])
      })
    )
  end

  defp field!(line) do
    [key, value] = String.split(line, ":", parts: 2)
    {String.trim(key), String.trim(value)}
  end

  defp kind!("fix"), do: :fix
  defp kind!("question"), do: :question

  defp checked!(nil), do: nil
  defp checked!(date), do: Date.from_iso8601!(date)
end
