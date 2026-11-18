defmodule PatchbayWeb.ConnCase do
  use ExUnit.CaseTemplate

  alias Patchbay.Accounts.SessionAuthority

  using do
    quote do
      # The default endpoint for testing
      @endpoint PatchbayWeb.Endpoint

      use PatchbayWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PatchbayWeb.ConnCase
    end
  end

  setup tags do
    Patchbay.DataCase.setup_sandbox(tags)
    Patchbay.JevStandIn.accept_posts()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "The request sent to the open address (`PatchbayWeb.SiteEdition`) instead."
  def on_open(conn), do: %{conn | host: PatchbayWeb.SiteEdition.open_host()}

  @doc """
  The app address a person's Allow or Cancel returns them to: the consent
  form's answer is a page that goes there by itself and links there too.
  """
  def returned_to(conn) do
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "location") == []
    [_, refresh] = Regex.run(~r/<meta http-equiv="refresh" content="0;url=([^"]+)">/, conn.resp_body)
    [_, link] = Regex.run(~r/<a href="([^"]+)">Continue<\/a>/, conn.resp_body)
    assert refresh == link

    link
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  @doc """
  The request from a browser signed in as `profile_id` at `signed_in_at`, as
  the sign-in endpoint leaves its cookie: a bound sign-in lineage
  (`Patchbay.Accounts.SessionAuthority`) merged into the test session.
  """
  def sign_in(conn, profile_id, signed_in_at \\ DateTime.utc_now()),
    do: Plug.Test.init_test_session(conn, signed_in_session(profile_id, signed_in_at))

  @doc "The cookie session of a browser signed in as `profile_id` at `signed_in_at`."
  def signed_in_session(profile_id, signed_in_at \\ DateTime.utc_now()) do
    {:bootstrap, claim} = SessionAuthority.renew(nil)
    {:ok, :bind, claim} = SessionAuthority.sign_in(claim, profile_id, signed_in_at)
    SessionAuthority.session(claim)
  end

  @doc """
  What a page drawn for the browser holding `session` signs into its LiveView
  token (`PatchbayWeb.CurrentProfile.render_context/1`), for `live_isolated/3`.
  """
  def rendered_for(%{"session_lineage" => lineage}, route \\ "/"),
    do: %{"render_topic" => SessionAuthority.topic(lineage), "render_route" => route}
end
