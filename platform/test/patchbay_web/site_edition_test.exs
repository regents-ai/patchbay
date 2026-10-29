defmodule PatchbayWeb.SiteEditionTest do
  @moduledoc """
  The two addresses (`PatchbayWeb.SiteEdition`): which one a request came to,
  each one's origin, and the route sweep — every route kept to one address is
  a missing page at the other, and the money pages, native MCP, ChatGPT's
  connection and its tools are each kept to the right one.
  """

  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SiteEdition

  @main_only ~w(
    /offers /offers/bid /offers/create /admin/offers /points /credits-help /priority
    /fixes/:id /bench/x402-test /siwa-test /mcp /tools/account/balances
    /forum/offer-slots /forum/offer-reports /forum/offer-bids /forum/my-offers
    /forum/my-offers/:creative_id /forum/credits-help /forum/credits-help/:id
    /forum/reports/:id/accept /forum/reports/:id/refund /reports/:id/refund /posts/:id/refund
    /api/agent/payment_intents /api/agent/assists /api/payment_intents /api/assists/:id
    /api/me/usdc_balance
  )

  @open_only ~w(
    /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/chatgpt/mcp
    /.well-known/oauth-authorization-server /.well-known/openai-apps-challenge
    /oauth/register /oauth/token /oauth/revoke /oauth/authorize /oauth/connections
    /chatgpt/mcp /chatgpt/agent/mcp
  )

  test "a request is the open edition only at the open host", %{conn: conn} do
    assert get(conn, "/healthz").assigns.site_edition == :main
    assert (conn |> on_open() |> get("/healthz")).assigns.site_edition == :open
  end

  test "each edition's origin keeps the site's scheme and port and names its own host" do
    main = URI.parse(SiteEdition.url(:main))
    open = URI.parse(SiteEdition.url(:open))

    assert open.host == SiteEdition.open_host()
    assert {open.scheme, open.port} == {main.scheme, main.port}
    refute open.host == main.host
  end

  test "the plan's routes are kept to the address they belong to" do
    assert MapSet.subset?(MapSet.new(@main_only), paths(:main_only))
    assert MapSet.subset?(MapSet.new(@open_only), paths(:open_only))
  end

  test "every route kept to patchbay.help is a missing page at the open address", %{conn: conn} do
    for route <- routes(:main_only), do: assert_missing(on_open(conn), route)
  end

  test "every route kept to the open address is a missing page at patchbay.help", %{conn: conn} do
    for route <- routes(:open_only), do: assert_missing(conn, route)
  end

  test "each door still answers at its own address", %{conn: conn} do
    assert conn |> get("/mcp") |> response(405)
    assert conn |> on_open() |> get("/chatgpt/mcp") |> response(405)
    assert conn |> get("/priority") |> html_response(200)
  end

  test "a connected page the other address does not have goes to the home page" do
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, ^socket} =
             SiteEdition.on_mount(:main, %{}, %{"site_edition" => :main}, socket)

    assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} =
             SiteEdition.on_mount(:main, %{}, %{"site_edition" => :open}, socket)
  end

  test "a page tells its agents the origin of the address it was read at", %{conn: conn} do
    assert conn |> get("/") |> html_response(200) =~
             ~s(name="agent-request-origin" content="#{SiteEdition.url(:main)}")

    assert conn |> on_open() |> get("/") |> html_response(200) =~
             ~s(name="agent-request-origin" content="#{SiteEdition.url(:open)}")
  end

  # Every route, with the pipelines the router sends it through.
  defp routes(pipeline) do
    for route <- PatchbayWeb.Router.__routes__(),
        verb = route.verb |> to_string() |> String.upcase(),
        path = String.replace(route.path, ~r/:[a-z_]+/, Ecto.UUID.generate()),
        info = Phoenix.Router.route_info(PatchbayWeb.Router, verb, path, "any"),
        pipeline in info.pipe_through,
        do: %{verb: verb, path: path, route: route.path}
  end

  defp paths(pipeline), do: MapSet.new(routes(pipeline), & &1.route)

  defp assert_missing(conn, %{verb: verb, path: path}),
    do: assert_error_sent(404, fn -> dispatch(conn, @endpoint, verb, path) end)
end
