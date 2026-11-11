defmodule PatchbayWeb.LiveSessionSaltTest do
  @moduledoc """
  A tab opened before v349 reloads, never crashes. Its pages were signed with the
  salt the site used then, and their sessions had no `site_edition` (it arrived
  on 29 October), so mounting the signed-in header (crash 333) or the search box
  (crash 334) raised. v349 changed the salt (config.exs): a page signed with the
  old one is now refused as out of date, and the browser loads the page again
  with the session it needs.
  """

  use PatchbayWeb.ConnCase, async: true

  import Phoenix.ChannelTest

  alias Phoenix.LiveView.Static

  @endpoint PatchbayWeb.Endpoint
  @salt_before_v349 "NjIe8lvc"

  test "every view on a page signed before v349 reloads instead of crashing", %{conn: conn} do
    person =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:salt-before-v349",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    signed_in =
      conn
      |> Plug.Test.init_test_session(%{})
      |> PatchbayWeb.Plugs.CurrentProfile.sign_in(person.id)

    pages = [get(conn, "/"), get(signed_in, "/")]

    replies =
      for page <- pages, {%{id: id, session: session} = term, static} <- views(page) do
        {:error, %{reason: reason}} =
          join(live_socket(get_session(page)), Phoenix.LiveView.Channel, "lv:" <> id, %{
            "session" =>
              signed_before_v349(%{term | session: Map.delete(session, "site_edition")}),
            "static" => signed_before_v349(static),
            "params" => %{"_mounts" => 0}
          })

        {term.view, reason}
      end

    assert {PatchbayWeb.HeaderAccountLive, "stale"} in replies
    assert {PatchbayWeb.SearchLive, "stale"} in replies
    assert Enum.all?(replies, fn {_view, reason} -> reason == "stale" end)
  end

  # The socket carries the page's cookie, as a browser's does.
  defp live_socket(cookie) do
    socket = socket(Phoenix.LiveView.Socket, nil, %{})
    %{socket | private: Map.put(socket.private, :connect_info, %{session: cookie})}
  end

  defp views(page) do
    page
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-phx-session]")
    |> Enum.map(&decoded/1)
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
