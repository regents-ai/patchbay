defmodule PatchbayWeb.LiveSessionSaltTest do
  @moduledoc """
  A tab opened before v349 reloads, never crashes. Its pages were signed with the
  salt the site used then, and their search box's session had no `site_edition`
  (it arrived on 29 October), so mounting it raised. v349 changed the salt
  (config.exs): a page signed with the old one is now refused as out of date, and
  the browser loads the page again with the session it needs.
  """

  use PatchbayWeb.ConnCase, async: true

  import Phoenix.ChannelTest

  alias Phoenix.LiveView.Static

  @endpoint PatchbayWeb.Endpoint
  @salt_before_v349 "NjIe8lvc"

  test "every view on a page signed before v349 reloads instead of crashing", %{conn: conn} do
    views =
      conn
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-phx-session]")
      |> Enum.map(&decoded/1)

    assert PatchbayWeb.SearchLive in Enum.map(views, fn {term, _static} -> term.view end)

    for {%{id: id, session: session} = term, static} <- views do
      assert {:error, %{reason: "stale"}} =
               join(live_socket(), Phoenix.LiveView.Channel, "lv:" <> id, %{
                 "session" =>
                   signed_before_v349(%{term | session: Map.delete(session, "site_edition")}),
                 "static" => signed_before_v349(static),
                 "params" => %{"_mounts" => 0}
               })
    end
  end

  defp live_socket do
    socket = socket(Phoenix.LiveView.Socket, nil, %{})
    %{socket | private: Map.put(socket.private, :connect_info, %{session: %{}})}
  end

  defp decoded(view) do
    {:ok, term} = Static.verify_token(@endpoint, attribute(view, "data-phx-session"))
    {:ok, static} = Static.verify_token(@endpoint, attribute(view, "data-phx-static"))
    {term, static}
  end

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp signed_before_v349(data),
    do: Phoenix.Token.sign(@endpoint, @salt_before_v349, {Static.token_vsn(), data})
end
