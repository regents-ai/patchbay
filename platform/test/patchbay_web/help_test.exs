defmodule PatchbayWeb.HelpTest do
  @moduledoc """
  `get_patchbay_help` is one answer: a page's tool reads it from
  `GET /forum/help` and `/mcp` gives it, each listing every tool it offers
  under the manifest's purpose, with the same purpose sentence and rules. At
  the open address a page's help lists only the tools its pages offer.
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum.Capabilities

  test "the page's help and the hosted help are one answer for their own tools", %{conn: conn} do
    page = conn |> get("/forum/help") |> json_response(200)

    hosted =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "get_patchbay_help", arguments: %{}}
        })
      )
      |> json_response(200)
      |> get_in(["result", "structuredContent"])

    on_page = for %{availability: "available"} = tool <- Capabilities.site(), do: tool.name
    at_mcp = Enum.map(PatchbayWeb.MCP.Tools.list(:native_mcp), & &1.name)

    assert Enum.map(page["available_tasks"], & &1["tool"]) |> Enum.sort() == Enum.sort(on_page)
    assert Enum.map(hosted["available_tasks"], & &1["tool"]) |> Enum.sort() == Enum.sort(at_mcp)

    purposes = Map.new(Capabilities.tools(), &{&1.name, &1.purpose})

    for task <- page["available_tasks"] ++ hosted["available_tasks"],
        do: assert(task["goal"] == purposes[task["tool"]])

    assert page["purpose"] == hosted["purpose"]
    assert page["posting_rules"] == hosted["posting_rules"]
    assert page["posting_rules"] == Capabilities.posting_rules()
  end

  test "at the open address a page's help names none of the tools it leaves out", %{conn: conn} do
    page = conn |> on_open() |> get("/forum/help") |> json_response(200)
    left_out = PatchbayWeb.SiteEdition.left_out_tools(:open)

    offered =
      for %{availability: "available", name: name} <- Capabilities.site(),
          name not in left_out,
          do: name

    assert Enum.map(page["available_tasks"], & &1["tool"]) |> Enum.sort() == Enum.sort(offered)
    refute page["not_available_here"] =~ ~r/paid|tip/i
  end
end
