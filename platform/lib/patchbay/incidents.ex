defmodule Patchbay.Incidents do
  @moduledoc """
  The incident pages, one Markdown file each in `priv/incidents`, read when
  the app is built. The file's name is the page's: `emudhra.md` is
  `/incidents/emudhra`.

  A file opens with its facts between two `---` lines, one `key: value` a
  line, the value in double quotes or bare: `title`, `summary`, `date`,
  `checked`, the day its sources were last read, `status` (`active` or
  `closed`), the forum `tag` its discussion carries, `post_site`, the site
  whose board its discussion is on, and `check_again`, when to read the page
  again. The rest is the briefing in Markdown, the opening post of the
  incident's discussion (`Patchbay.Incidents.Discussion`). A file missing a
  fact, or carrying another, does not build.

  A later incident is one more file. Closing one is setting its status to
  `closed`: its page and discussion stay, and the home page stops pointing at
  it. A file is never taken away, because its discussion's address is its page.
  """

  @typedoc "One incident: its facts, and its text as Markdown."
  @type t :: %{
          name: String.t(),
          title: String.t(),
          summary: String.t(),
          date: Date.t(),
          checked: Date.t(),
          status: :active | :closed,
          tag: String.t(),
          post_site: String.t(),
          check_again: String.t(),
          body: String.t()
        }

  @root Path.expand("../..", __DIR__)
  @files Application.compile_env!(:patchbay, :incident_files)
  @paths @files |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1))) |> Enum.sort()
  for path <- @paths, do: @external_resource(path)

  @incidents (for path <- @paths do
                ["", facts, body] = String.split(File.read!(path), ~r/^---\n/m, parts: 3)

                facts =
                  facts
                  |> String.split("\n", trim: true)
                  |> Map.new(fn line ->
                    [key, value] = String.split(line, ": ", parts: 2)
                    {key, value |> String.trim() |> String.trim("\"")}
                  end)

                ~w(check_again checked date post_site status summary tag title) =
                  facts |> Map.keys() |> Enum.sort()

                %{
                  name: Path.basename(path, ".md"),
                  title: facts["title"],
                  summary: facts["summary"],
                  date: Date.from_iso8601!(facts["date"]),
                  checked: Date.from_iso8601!(facts["checked"]),
                  status:
                    case facts["status"] do
                      "active" -> :active
                      "closed" -> :closed
                    end,
                  tag: facts["tag"],
                  post_site: facts["post_site"],
                  check_again: facts["check_again"],
                  body: String.trim(body)
                }
              end)
             |> Enum.sort_by(& &1.date, {:desc, Date})
             |> Enum.sort_by(&(&1.status == :closed))

  @doc "Every incident: the active ones first, each kind newest first."
  @spec all() :: [t()]
  def all, do: @incidents

  @doc "The incident a page name names, or nil."
  @spec get(String.t()) :: t() | nil
  def get(name), do: Enum.find(@incidents, &(&1.name == name))

  @doc "The incidents still going on, newest first."
  @spec active() :: [t()]
  def active, do: Enum.filter(@incidents, &(&1.status == :active))

  # A file added or taken away rebuilds the list.
  def __mix_recompile__? do
    Enum.sort(Enum.flat_map(@files, &Path.wildcard(Path.join(@root, &1)))) != @paths
  end
end
