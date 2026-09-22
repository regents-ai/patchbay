defmodule PatchbayWeb.Forum.FixTest do
  @moduledoc """
  The fix form at the top of the home page: a free fix opens for the
  connection and the page goes to it; a second one waits for the first; a
  used-up connection is told to sign in, and a signed-in person gets two
  more, then the fee; and a request Patchbay would not act on comes back to
  the form with the words for it and what was typed.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @wallet "0x" <> String.duplicate("d", 40)

  @form %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "expected_result" => "A confirmation with a booking reference",
    "sign_in" => "unknown",
    "tool" => "reserve_table",
    "arguments" => ~s({"party": 2})
  }

  setup do
    old_assist = Application.get_env(:patchbay, :assist)
    Application.put_env(:patchbay, :assist, pay_to_address: @wallet)
    on_exit(fn -> Application.put_env(:patchbay, :assist, old_assist) end)
    :ok
  end

  test "the home page opens on the fix form, free for a new connection", %{conn: conn} do
    html = conn |> from(address()) |> get(~p"/") |> html_response(200)

    assert html =~ "Issues with MCP? Patchbay will fix it fast with Jev"
    assert html =~ ~s(data-pb-fix-mode="free")
    assert html =~ "1 free fix left today from this connection, and 2 more when you sign in"
    assert html =~ "Patchbay Credits"
    refute html =~ "Rewards"
  end

  test "a free fix opens for the connection and the page goes to it", %{conn: conn} do
    address = address()
    conn = conn |> from(address) |> post(~p"/fixes", %{"fix" => @form})
    assert "/fixes/" <> id = redirected_to(conn)

    # The test reads the run as Patchbay itself would, to check what was written.
    {:ok, run} = Assist.get_run(id, authorize?: false)
    assert run.grant == :visitor
    assert run.status == :paid
    assert run.goal == @form["goal"]
    assert run.site_url == @form["site_url"]
    assert run.believed_calls == [%{"tool" => "reserve_table", "arguments" => %{"party" => 2}}]
    assert run.browser_session_id == get_session(conn, "forum_session_id")
    assert is_nil(run.payer_profile_id)
    assert is_binary(run.visitor_key)
    refute run.visitor_key =~ address

    # Asking again from the same browser shows the fix under way, not a second one.
    again =
      conn
      |> recycle()
      |> put_req_header("fly-client-ip", address)
      |> post(~p"/fixes", %{"fix" => @form})

    assert redirected_to(again) == "/fixes/#{id}"
    close(run)

    # The connection's free fix is used: a fresh browser on it is told to sign in.
    html = build_conn() |> from(address) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(data-pb-fix-mode="sign_in")

    refused = build_conn() |> from(address) |> post(~p"/fixes", %{"fix" => @form})
    html = html_response(refused, 200)
    assert html =~ "free fix for today is used. Sign in for two more"
    assert html =~ ~s(value="#{@form["goal"]}")
  end

  test "a signed-in person gets two more, then pays the fee", %{conn: conn} do
    address = address()
    person = person()

    {:ok, used} =
      Assist.request_free_run(request(), :visitor, key(address), Ash.UUID.generate(), nil)

    close(used)

    html = conn |> from(address) |> signed_in(person) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(data-pb-fix-mode="free")
    assert html =~ "2 free fixes left today from this connection."

    for _turn <- 1..2 do
      posted =
        build_conn() |> from(address) |> signed_in(person) |> post(~p"/fixes", %{"fix" => @form})

      assert "/fixes/" <> id = redirected_to(posted)
      # Read as Patchbay itself, to check what was written.
      {:ok, run} = Assist.get_run(id, authorize?: false)
      assert run.grant == :member
      assert run.payer_profile_id == person.id
      close(run)
    end

    html = build_conn() |> from(address) |> signed_in(person) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(data-pb-fix-mode="pay")
    assert html =~ "Fix it for 0.10 USDC"
    assert html =~ "paid with Patchbay Credits from the wallet you signed in with"

    refused =
      build_conn() |> from(address) |> signed_in(person) |> post(~p"/fixes", %{"fix" => @form})

    assert html_response(refused, 200) =~ "The next one is 0.10 USDC with Patchbay Credits."
  end

  test "a request Patchbay would not act on comes back to the form", %{conn: conn} do
    address = address()

    for {change, words} <- [
          {%{"sign_in" => "required"}, "never acts on anyone"},
          {%{"arguments" => "junk"}, "JSON object"},
          {%{"site_url" => "http://bookings.example.com"}, "public https address"},
          {%{"goal" => ""}, "Say what you were trying to do"}
        ] do
      html =
        build_conn()
        |> from(address)
        |> post(~p"/fixes", %{"fix" => Map.merge(@form, change)})
        |> html_response(200)

      assert html =~ words, "#{inspect(change)} should say #{words}"
      assert html =~ ~s(value="#{@form["expected_result"]}")
    end

    # Nothing was opened, and the connection's free fix is still there.
    assert conn |> from(address) |> get(~p"/") |> html_response(200) =~
             ~s(data-pb-fix-mode="free")
  end

  test "an IPv6 connection is counted by its network, so a new address in it is no new free fix" do
    assert key("2001:db8:1:2::1") == key("2001:db8:1:2:ffff:ffff:ffff:fffe")
    refute key("2001:db8:1:2::1") == key("2001:db8:1:3::1")
    assert key("::ffff:203.0.113.9") == key("203.0.113.9")
    refute key("203.0.113.9") == key("203.0.113.10")
  end

  defp from(conn, address), do: put_req_header(conn, "fly-client-ip", address)

  defp signed_in(conn, person) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(CurrentProfile.session_key(), person.id)
  end

  defp key(address), do: PatchbayWeb.ClientAddress.visitor_key(from(build_conn(), address))

  defp address, do: "203.0.113.#{System.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}"

  defp request do
    %{
      "goal" => @form["goal"],
      "site_url" => @form["site_url"],
      "believed_calls" => [],
      "sign_in" => "unknown",
      "expected_result" => @form["expected_result"]
    }
  end

  # Closing a run the way Patchbay's own worker does, so the next may open.
  defp close(run) do
    # The worker's own moves on the run it works on.
    {:ok, running} = Assist.start_run(run, authorize?: false)

    # Same: the worker closing its own run.
    {:ok, _done} =
      Assist.finish_run(running, %{status: :finished, outcome: :not_possible}, authorize?: false)
  end

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:fix-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("c", 40)
    })
  end
end
