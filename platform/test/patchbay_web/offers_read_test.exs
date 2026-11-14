defmodule PatchbayWeb.OffersReadTest do
  @moduledoc """
  Agents read the offer market at three doors, `GET /api/offers`,
  `/offers.md` and the `read_offers` tool at `/mcp`
  (`PatchbayWeb.OffersController`): each answers the same record, only at
  patchbay.help, and nothing while no market is set, when `/capabilities.json`
  shows the operation closed.
  """

  use PatchbayWeb.ConnCase, async: false

  import PatchbayTest.OfferFixtures

  alias PatchbayWeb.OpenAPIShape

  test "with no market set, every door answers not_found and the operation is closed",
       %{conn: conn} do
    over_http = conn |> get("/api/offers") |> json_response(404)
    assert over_http["error"]["code"] == "not_found"

    assert %{"isError" => true} = result = read_offers(conn)
    assert refusal(result) == over_http

    assert_error_sent 404, fn -> conn |> recycle() |> get("/offers.md") end

    assert %{"gate" => %{"state" => "closed", "reason" => reason}, "agent_use" => "closed"} =
             operation(conn)

    assert is_binary(reason)
  end

  test "an open market reads the same at every door", %{conn: conn} do
    offers_on!()
    campaign = campaign!(person!(wallet()))
    placement!(1, "stripe.com")
    placement!(9, "general")
    lease!(1, 1, campaign, %{paid_usdc: Decimal.new(12_000_000)})

    body = conn |> get("/api/offers") |> json_response(200)
    spec = conn |> recycle() |> get("/openapi.json") |> json_response(200)
    OpenAPIShape.assert_shape(spec, OpenAPIShape.response_schema(spec, "/api/offers"), body)

    # Patchbay's own placements come first, and name no site.
    assert %{"placements" => [general, placement], "up_to_date" => up_to_date} = body
    assert %{"placement_id" => 9, "site" => nil} = general
    assert is_boolean(up_to_date)

    assert %{
             "placement_id" => 1,
             "name" => "stripe.com",
             "site" => "stripe.com",
             "lease_hours" => 72,
             "floor_usdc" => "5.00",
             "buyout_step_bps" => 1_000,
             "slots" => [open, leased, _last]
           } = placement

    assert %{"slot" => 0, "offer" => nil, "paid_usdc" => nil, "ends_at" => nil} = open
    assert open["minimum_usdc"] == "5.00"

    # A buyout pays the lease's price and the placement's 10% step.
    assert %{"slot" => 1, "paid_usdc" => "12.00", "minimum_usdc" => "13.20"} = leased
    assert leased["offer"]["campaign_id"] == campaign.campaign_id
    assert leased["offer"]["advertiser"] == campaign.advertiser
    assert {:ok, _ends_at, 0} = DateTime.from_iso8601(leased["ends_at"])
    assert %URI{path: "/offers", query: "placement=1&slot=1"} = URI.parse(leased["page"])

    assert %{"isError" => false, "structuredContent" => ^body} = read_offers(conn)

    markdown = conn |> recycle() |> get("/offers.md")
    assert ["text/markdown" <> _charset] = get_resp_header(markdown, "content-type")
    assert response(markdown, 200) =~ "(#{leased["page"]})"
    assert markdown.resp_body =~ campaign.title

    assert %{"gate" => %{"state" => "open"}, "agent_use" => "run"} = operation(conn)
  end

  test "the open address answers nothing about offers, even with a market", %{conn: conn} do
    offers_on!()

    for path <- ~w(/api/offers /offers.md) do
      assert_error_sent 404, fn -> conn |> on_open() |> get(path) end
    end

    operations = conn |> on_open() |> get("/capabilities.json") |> json_response(200)
    refute Enum.any?(operations["operations"], &(&1["operation"] == "readOffers"))
  end

  defp operation(conn) do
    conn
    |> recycle()
    |> get("/capabilities.json")
    |> json_response(200)
    |> Map.fetch!("operations")
    |> Enum.find(&(&1["operation"] == "readOffers"))
  end

  defp read_offers(conn) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "read_offers", arguments: %{}}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp refusal(%{"content" => [%{"text" => text}]}), do: Jason.decode!(text)
end
