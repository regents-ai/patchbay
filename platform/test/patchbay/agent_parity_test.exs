defmodule Patchbay.AgentParityTest do
  @moduledoc """
  `docs/agent-parity.md` lists every action with its four surfaces: the
  website, WebMCP, the hosted tools at /mcp, and the command line. This holds
  the file to the code: a tool added to the manifest without a row, a cell
  naming a tool or command that is not that row's or not offered there, or a
  gap on a surface that does offer the row's tool, fails the suite.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Capabilities

  @parity "../docs/agent-parity.md"
  @commands "../cli/commands.json"
  @header ["Action", "Tools", "Website", "WebMCP", "/mcp", "CLI"]
  @gap ~r/\AGAP PB-\d+ \((Patchbay|template|regents-cli)\)/

  setup_all do
    lines = @parity |> File.read!() |> String.split("\n")
    [header | rest] = Enum.drop_while(lines, &(cells(&1) != @header))

    rows =
      rest
      |> Enum.drop(1)
      |> Enum.take_while(&String.starts_with?(&1, "|"))
      |> Enum.map(&Map.new(Enum.zip(cells(header), cells(&1))))

    # Each command, without its arguments, and the tool its `webmcp` names (nil for none).
    commands =
      for %{"command" => command} = entry <-
            @commands |> File.read!() |> Jason.decode!() |> Map.fetch!("commands"),
          into: %{},
          do: {String.replace(command, ~r/\s*<[^>]+>/, ""), entry["webmcp"]}

    page =
      for tool <- Capabilities.manifest()["tools"],
          tool["scope"] == "site",
          do: tool["name"]

    hosted = Enum.map(PatchbayWeb.MCP.Tools.list(:native_mcp), & &1.name)

    %{rows: rows, commands: commands, page: page, hosted: hosted}
  end

  test "every manifest tool has one row, and every tool a row names is in the manifest", %{
    rows: rows
  } do
    named = Enum.flat_map(rows, &names(&1["Tools"]))
    manifest = Capabilities.names()

    assert manifest -- named == [], "manifest tools with no row in #{@parity}"
    assert Enum.uniq(named -- manifest) == [], "rows naming tools the manifest does not have"
    assert named -- Enum.uniq(named) == [], "tools listed in more than one row"
  end

  test "each surface names the row's own tools it offers, or a gap no tool there fills", %{
    rows: rows,
    commands: commands,
    page: page,
    hosted: hosted
  } do
    for row <- rows do
      tools = names(row["Tools"])

      # What each surface offers this row: the row's tools that it runs, and
      # for the CLI the commands that serve one of them.
      offered = %{
        "WebMCP" => Enum.filter(tools, &(&1 in page)),
        "/mcp" => Enum.filter(tools, &(&1 in hosted)),
        "CLI" => for({command, tool} <- commands, tool in tools, do: command)
      }

      # Beside the row's own, the CLI may name commands that serve no tool.
      allowed = %{
        offered
        | "CLI" => offered["CLI"] ++ for({command, nil} <- commands, do: command)
      }

      for column <- ["WebMCP", "/mcp", "CLI"] do
        cell = Map.fetch!(row, column)
        where = "#{row["Action"]} (#{column})"

        cond do
          String.starts_with?(cell, "GAP") ->
            assert cell =~ @gap, "#{where}: a gap names its PB ticket and its lane"

            assert offered[column] == [],
                   "#{where} is a gap, yet offers #{inspect(offered[column])}"

          String.starts_with?(cell, "n/a:") ->
            assert tools == ["prepare_agent_request"],
                   "#{where}: n/a is for prepare_agent_request only"

          true ->
            names = names(cell)
            assert names != [], "#{where} names nothing and is not a gap"
            assert names -- allowed[column] == [], "#{where} names what is not this row's there"
        end
      end
    end
  end

  defp cells(line) do
    line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
  end

  defp names(cell), do: for([_, name] <- Regex.scan(~r/`([^`]+)`/, cell), do: name)
end
