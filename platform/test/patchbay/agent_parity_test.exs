defmodule Patchbay.AgentParityTest do
  @moduledoc """
  `docs/agent-parity.md` lists every action with its four surfaces: the
  website, WebMCP, the hosted tools at /mcp, and the command line. This holds
  the file to the code, so a tool added to the manifest without a row, or a row
  naming a tool, hosted tool or command that is not there, fails the suite.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Capabilities

  @parity "../docs/agent-parity.md"
  @commands "../cli/commands.json"
  @header ["Action", "Tools", "Website", "WebMCP", "/mcp", "CLI"]
  @gap ~r/\AGAP (PB-\d+|untracked) \((Patchbay|template|regents-cli)\)/

  setup_all do
    lines = @parity |> File.read!() |> String.split("\n")
    [header | rest] = Enum.drop_while(lines, &(cells(&1) != @header))

    rows =
      rest
      |> Enum.drop(1)
      |> Enum.take_while(&String.starts_with?(&1, "|"))
      |> Enum.map(&Map.new(Enum.zip(cells(header), cells(&1))))

    %{rows: rows}
  end

  test "every manifest tool has a row, and every tool a row names is in the manifest", %{
    rows: rows
  } do
    named = Enum.flat_map(rows, &names(&1["Tools"]))
    manifest = Capabilities.names()

    assert manifest -- named == [], "manifest tools with no row in #{@parity}"
    assert Enum.uniq(named -- manifest) == [], "rows naming tools the manifest does not have"
    assert named -- Enum.uniq(named) == [], "tools listed in more than one row"
  end

  test "each surface names what that surface offers, or a gap with its ticket and lane", %{
    rows: rows
  } do
    page =
      for tool <- Capabilities.manifest()["tools"],
          tool["doors"]["page"] or String.starts_with?(tool["scope"], "page:"),
          do: tool["name"]

    hosted = Enum.map(PatchbayWeb.MCP.Tools.list(:native_mcp), & &1.name)

    commands =
      for %{"command" => command} <-
            @commands |> File.read!() |> Jason.decode!() |> Map.fetch!("commands"),
          do: command |> String.replace(~r/\s*<[^>]+>/, "")

    for row <- rows,
        {column, offered} <- [{"WebMCP", page}, {"/mcp", hosted}, {"CLI", commands}] do
      cell = Map.fetch!(row, column)

      cond do
        String.starts_with?(cell, "GAP") ->
          assert cell =~ @gap,
                 "#{row["Action"]} (#{column}): a gap names PB-n or untracked, and its lane"

        String.starts_with?(cell, "n/a:") ->
          :ok

        true ->
          names = names(cell)
          assert names != [], "#{row["Action"]} (#{column}) names nothing and is not a gap"

          assert names -- offered == [],
                 "#{row["Action"]} (#{column}) names what #{column} does not offer"
      end
    end
  end

  defp cells(line) do
    line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
  end

  defp names(cell), do: for([_, name] <- Regex.scan(~r/`([^`]+)`/, cell), do: name)
end
