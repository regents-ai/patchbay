defmodule PatchbayWeb.SiteEditionTest do
  @moduledoc """
  The two addresses (`PatchbayWeb.SiteEdition`): which one a request came to,
  each one's origin, and what a page read at one tells its agents.
  """

  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SiteEdition

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
end
