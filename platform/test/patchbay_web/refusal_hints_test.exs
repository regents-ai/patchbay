defmodule PatchbayWeb.RefusalHintsTest do
  @moduledoc """
  A refusal's hint and an answer's next step tell an agent what to run: a
  command or a tool, never a web route it would have to turn into a call, and
  never a web address with a placeholder left in it. A placeholder as a
  command's argument (`regents patchbay requests get CLIENT-REQUEST-ID`,
  `--query WORDS`) is how a command is written, and is fine.

  Two sources are read: every hint and next step `openapi.json` documents, and
  every one-line string the site's code and page tools are built from
  (`lib/**/*.ex`, `assets/js/**/*.ts`, documentation and comments aside), so a
  hint the code makes but the API never documents is held too. The few strings that are not advice to an
  agent but name a route on purpose are listed, each with why.
  """

  use ExUnit.Case, async: true

  @root Application.app_dir(:patchbay)
  @source Path.expand("../..", __DIR__)

  # A method and a path, an address under the API's own prefixes, or a
  # capitalised placeholder after a slash or an equals sign in an address.
  # The website's pages (/webmcp, /offers/active) are places a person or agent
  # opens, not calls, and may be named.
  @route ~r"\b(GET|POST|PUT|PATCH|DELETE) /|/(forum|api|known-fixes)\b|(/|=)[A-Z][A-Z_]{2,}\b(?!\.)"

  @named_on_purpose %{
    # The exact request an agent signs to test its sign-in.
    "lib/patchbay_web/plugs/siwa_test_proof.ex" => ["GET /siwa-test"],
    # A site's page on Patchbay, which the agent guides ask the reader to fill in.
    "lib/patchbay_web/forum/agent_pages.ex" => ["/HOST?goal=GOAL&error=ERROR"],
    "lib/patchbay_web/controllers/forum/board_html.ex" => ["/HOST?goal=GOAL&error=ERROR"],
    # The ask form's sample page address, replaced by the asker.
    "lib/patchbay_web/controllers/forum/board_controller.ex" => [
      "https://THE-EXACT-PAGE-YOU-WERE-ON"
    ],
    # A time zone, not an address.
    "lib/patchbay_web/controllers/sitemap_controller.ex" => ["Etc/UTC"]
  }

  test "no documented hint or next step names a route or a placeholder address" do
    found =
      Path.join(@root, "priv/public/openapi.json")
      |> File.read!()
      |> Jason.decode!()
      |> advice([])
      |> Enum.filter(fn {_where, words} -> words =~ @route end)

    assert found == []
  end

  test "no string the code builds hints or next steps from names a route or a placeholder address" do
    found =
      for pattern <- ["lib/**/*.ex", "assets/js/**/*.ts"],
          file <- Path.wildcard(Path.join(@source, pattern)),
          relative = Path.relative_to(file, @source),
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not documentation?(line),
          words <- quoted(line, Path.extname(file)),
          # Prose, not an address the code itself calls or routes.
          String.contains?(words, " "),
          words =~ @route,
          not Enum.any?(Map.get(@named_on_purpose, relative, []), &String.contains?(words, &1)),
          do: "#{relative}:#{number}: #{words}"

    assert found == []
  end

  # The strings on a line: double-quoted, and in TypeScript template literals too.
  defp quoted(line, ".ts"), do: strings(~r/"((?:[^"\\]|\\.)*)"|`([^`]*)`/, line)
  defp quoted(line, ".ex"), do: strings(~r/"((?:[^"\\]|\\.)*)"/, line)

  defp strings(pattern, line),
    do: pattern |> Regex.scan(line, capture: :all_but_first) |> Enum.map(&Enum.join/1)

  # A module's or function's own documentation and comments describe the code.
  defp documentation?(line), do: line =~ ~r"^\s*(@doc|@moduledoc|#|//|\*)"

  defp advice(map, path) when is_map(map) do
    Enum.flat_map(map, fn
      {key, words} when key in ["hint", "next_step"] and is_binary(words) ->
        [{Enum.reverse([key | path]), words}]

      {key, value} ->
        advice(value, [key | path])
    end)
  end

  defp advice(list, path) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {value, i} -> advice(value, [i | path]) end)

  defp advice(_value, _path), do: []
end
