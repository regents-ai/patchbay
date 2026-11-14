defmodule PatchbayWeb.SessionChecksTest do
  # A page reads the sign-in once for its first answer and once as it connects,
  # and again at every navigation and press after that
  # (`PatchbayWeb.CurrentProfile`), so a sign-in revoked while the page is open
  # stops at the person's next one. The revocations here send no disconnect, as
  # a sign-in that ends on another machine of the site would not, so only the
  # page's own check can refuse. Each check reads the sign-in's session row
  # once. Adapted from ash-template's session_checks_test.exs.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Accounts.SessionAuthority
  alias Patchbay.Identity

  @signed_out "#account-signed-out"

  setup %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:session-checks-#{System.unique_integer([:positive])}",
        wallet_address: "0x" <> String.duplicate("d", 40)
      })

    cookie = signed_in_session(person.id)
    ref = make_ref()
    id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(id, [:patchbay, :repo, :query], &__MODULE__.session_read/4, {self(), ref})

    on_exit(fn -> :telemetry.detach(id) end)

    %{
      browser: init_test_session(conn, cookie),
      claim: SessionAuthority.claim(cookie),
      person: person,
      reads: ref
    }
  end

  @doc false
  def session_read(
        _event,
        _measurements,
        %{source: "session_authorities", query: "SELECT" <> _},
        {test, ref}
      ),
      do: send(test, {:session_read, ref})

  def session_read(_event, _measurements, _metadata, _config), do: :ok

  defp reads(ref, count \\ 0) do
    receive do
      {:session_read, ^ref} -> reads(ref, count + 1)
    after
      0 -> count
    end
  end

  test "the first answer and the connected page each read the sign-in once, and every navigation and press after that again",
       %{browser: browser, person: person, reads: ref} do
    conn = get(browser, ~p"/account/profile")
    assert reads(ref) == 1
    refute conn |> html_response(200) =~ ~s(id="account-signed-out")

    {:ok, view, _html} = live(conn)
    assert reads(ref) == 1
    refute has_element?(view, @signed_out)

    name = "checked-#{System.unique_integer([:positive])}"
    view |> element(".pb-name-form") |> render_submit(%{"name" => name})
    assert reads(ref) == 1
    assert Identity.get_profile!(person.id).agent_name == name

    render_patch(view, ~p"/account/inbox")
    assert reads(ref) == 1
    refute has_element?(view, @signed_out)
  end

  test "a sign-in revoked before the page connects connects signed out",
       %{browser: browser, claim: claim} do
    conn = get(browser, ~p"/account")
    SessionAuthority.revoke(claim)

    {:ok, view, _html} = live(conn)
    assert has_element?(view, @signed_out)
  end

  test "a sign-in revoked after the page connected is refused at the next navigation",
       %{browser: browser, claim: claim} do
    {:ok, view, _html} = live(browser, ~p"/account")
    SessionAuthority.revoke(claim)

    assert {:error, {:redirect, %{to: "/"}}} = render_patch(view, ~p"/account/inbox")
  end

  test "a press after the sign-in was revoked is refused, changes nothing and leaves the page signed out",
       %{browser: browser, claim: claim, person: person} do
    {:ok, view, _html} = live(browser, ~p"/account/profile")
    SessionAuthority.revoke(claim)

    view |> element(".pb-name-form") |> render_submit(%{"name" => "after-revoke"})

    assert has_element?(view, @signed_out)
    refute Identity.get_profile!(person.id).agent_name == "after-revoke"
  end

  test "a reader who never signed in is shown signed out, and a session row they hold is read once for each answer",
       %{conn: conn, reads: ref} do
    {:bootstrap, unbound} = SessionAuthority.renew(nil)

    for {session, each} <- [{%{}, 0}, {SessionAuthority.session(unbound), 1}] do
      page = conn |> init_test_session(session) |> get(~p"/account")
      assert reads(ref) == each
      assert html_response(page, 200) =~ ~s(id="account-signed-out")

      {:ok, view, _html} = live(page)
      assert reads(ref) == each
      assert has_element?(view, @signed_out)
    end
  end
end
