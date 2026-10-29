defmodule PatchbayWeb.CopyOpeningsTest do
  @moduledoc """
  Patchbay's own words for agents never open with who, what, where, why or when
  (founder, 28 Oct 2026): the command line's help, the tools' titles, the API's
  summaries, and the headings and bold leads of the agent guides, the skills and
  the incident pages, and every page's Markdown answer. The pages themselves are read by the browser walk
  (assets/test/browser/copy.desktop.spec.ts).
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @opening ~r/\A\s*(who|what|where|why|when)\b/i

  test "the command line's help, the tools' titles and the API's summaries" do
    for {file, keys} <- [
          {"cli/commands.json", ~w(title summary description help)},
          {"platform/priv/tool_manifest.json", ~w(title)},
          {"platform/priv/public/openapi.json", ~w(summary)}
        ] do
      found = file |> read_json() |> openings(keys, [])
      assert found == [], "#{file} opens with a W-word at #{inspect(found)}"
    end
  end

  test "the headings and bold leads of the guides, skills, incident pages and Markdown pages" do
    # The privacy and terms pages are versioned and change only on Sean's go; the
    # WebMCP guide is being rewritten on the agent-tools branch.
    twins =
      Path.wildcard(Path.join(@root, "platform/lib/patchbay_web/**/*.md.eex"))
      |> Enum.reject(&(Path.basename(&1) in ~w(privacy.md.eex terms.md.eex webmcp.md.eex)))

    files =
      twins ++
        Path.wildcard(Path.join(@root, "platform/priv/public/*.{md,txt}")) ++
        Path.wildcard(Path.join(@root, "platform/priv/incidents/*.md")) ++
        Path.wildcard(Path.join(@root, "skills/*/SKILL.md")) ++
        Path.wildcard(Path.join(@root, "plugins/patchbay/skills/*/SKILL.md")) ++
        Enum.map(~w(cli/README.md README.md), &Path.join(@root, &1))

    found =
      for file <- files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          lead = lead(line),
          lead && Regex.match?(@opening, lead),
          do: "#{Path.relative_to(file, @root)}:#{number}: #{lead}"

    assert found == []
  end

  defp read_json(file), do: @root |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp openings(map, keys, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      here = [key | path]

      if key in keys and is_binary(value) and Regex.match?(@opening, value),
        do: [here |> Enum.reverse() |> Enum.join("/")],
        else: openings(value, keys, here)
    end)
  end

  defp openings(list, keys, path) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, i} -> openings(value, keys, [i | path]) end)

  defp openings(_value, _keys, _path), do: []

  # A Markdown heading's words, or a line's bold lead.
  defp lead(line) do
    case Regex.run(~r/\A(?:#+\s+(.+)|\s*(?:[-*]\s+)?\*\*([^*]+)\*\*)/, line,
           capture: :all_but_first
         ) do
      [heading] -> heading
      ["", bold] -> bold
      nil -> nil
    end
  end
end
