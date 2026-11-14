defmodule PatchbayWeb.PrivySessionControllerTest do
  # Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
  # Privy makes every person an Ethereum wallet when they sign in; the page hands
  # the tokens over only once it exists, and the server still refuses a Privy
  # session with no wallet. Sean, 13 Nov 2026 ("143. a"): the browser's sign-in
  # session is ash-template's. Each browser here takes the steps
  # `assets/js/privy/session.ts` takes: the CSRF step, then Privy's two tokens,
  # signed as Privy signs them, with the token that step gave. The forgery check
  # is on for every sign-in step. Adapted from ash-template's
  # sign_in_wallets_test.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [has_element?: 2, live: 2]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import PatchbayWeb.ConnCase, only: [on_open: 1]

  alias Patchbay.Accounts.SessionAuthority
  alias Patchbay.Identity

  @endpoint PatchbayWeb.Endpoint
  @cookie "_patchbay_key"
  @own "0x" <> String.duplicate("e", 40)
  @made "0x" <> String.duplicate("7", 40)
  @sign_in_button ~s(data-account-target="sign-in")
  @email %{"type" => "email", "address" => "made@example.com", "lv" => 1_000}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Patchbay.Repo, shared: true)
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    privy = Application.get_env(:patchbay, :privy, [])

    Application.put_env(:patchbay, :privy,
      app_id: "test-app",
      verification_key: pem
    )

    on_exit(fn ->
      Application.put_env(:patchbay, :privy, privy)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    %{key: key, linked: [@email, wallet(@made, 1_001, "privy")]}
  end

  describe "the CSRF step" do
    test "starts a browser's session once, then only reads it, with or without an Accept header" do
      started = get(browser(), "/auth/csrf")

      assert %{"csrf_token" => token} = json_response(started, 200)
      assert is_binary(token)
      assert Map.has_key?(started.resp_cookies, @cookie)

      for accept <- [nil, "application/json"] do
        read = started |> recycle([]) |> accepting(accept) |> get("/auth/csrf")

        assert %{"csrf_token" => _token} = json_response(read, 200)
        refute Map.has_key?(read.resp_cookies, @cookie)
      end
    end

    test "tells a browser signed in again from another tab so, and one whose sign-in ended to start again",
         %{key: key, linked: linked} do
      did = did("csrf-states")
      first = sign_in(browser(), key, did, linked)
      again = sign_in(first, key, did, linked)
      assert json_response(again, 200)

      superseded = first |> recycle([]) |> get("/auth/csrf")
      assert %{"error" => %{"code" => "session_superseded"}} = json_response(superseded, 409)
      refute Map.has_key?(superseded.resp_cookies, @cookie)

      signed_out = again |> recycle([]) |> delete("/auth/privy/session")
      assert json_response(signed_out, 200) == %{"ok" => true}

      ended = again |> recycle([]) |> get("/auth/csrf")
      assert %{"error" => %{"code" => "session_reset_required"}} = json_response(ended, 409)

      assert %{"csrf_token" => _token} =
               ended |> recycle([]) |> get("/auth/csrf") |> json_response(200)
    end

    test "starts afresh for a cookie whose sign-in no server made" do
      forged = %{
        "session_lineage" => "not-a-lineage",
        "session_generation" => 1,
        "live_socket_id" => "session_authority:not-a-lineage"
      }

      started = browser() |> Plug.Test.init_test_session(forged) |> get("/auth/csrf")

      assert %{"csrf_token" => _token} = json_response(started, 200)
      assert signed_in_as(started) == nil

      refute started
             |> recycle([])
             |> get("/auth/csrf")
             |> Map.fetch!(:resp_cookies)
             |> Map.has_key?(@cookie)
    end

    test "starts at most the set number of sessions from one address, and the one refused leaves nothing" do
      budget = Application.fetch_env!(:patchbay, :session_bootstrap_rate_limit)
      from = browser()

      for _started <- 1..Keyword.fetch!(budget, :limit) do
        assert from |> get("/auth/csrf") |> json_response(200)
      end

      rows = Ash.count!(SessionAuthority, actor: %{role: :system})
      refused = get(from, "/auth/csrf")

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(refused, 429)
      assert get_resp_header(refused, "retry-after") == ["#{budget[:window_seconds]}"]
      refute Map.has_key?(refused.resp_cookies, @cookie)
      assert Ash.count!(SessionAuthority, actor: %{role: :system}) == rows

      assert browser() |> get("/auth/csrf") |> json_response(200)
    end
  end

  test "a sign-in failure the browser reports is taken without an answer, and only a known one is counted" do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, [:patchbay, :privy, :browser_failure], &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(id) end)

    for body <- [%{"reason" => "flow_closed"}, %{"reason" => "anything else"}, %{}] do
      assert browser() |> post("/auth/privy/failure", body) |> response(204) == ""
    end

    assert_received {:browser_failure, %{reason: "flow_closed"}}
    refute_received {:browser_failure, _metadata}
  end

  @doc false
  def forward(_event, _measurements, metadata, test), do: send(test, {:browser_failure, metadata})

  test "an email sign-in with the wallet Privy made signs in, and the page shows it signed in",
       %{key: key, linked: linked} do
    did = did("email")
    signed_in = sign_in(browser(), key, did, linked)

    assert json_response(signed_in, 200) == %{"authenticated" => true}
    assert signed_in_as(signed_in).wallet_address == @made
    # The person's shared profile, whose public name the Account page saves.
    assert {:ok, profile_id} = RegentIdentity.profile_id("test-app", did)
    assert is_binary(profile_id)

    assert signed_in |> recycle([]) |> get("/auth/session") |> json_response(200) ==
             %{"authenticated" => true}

    page = signed_in |> recycle([]) |> get("/account") |> html_response(200)
    refute page =~ @sign_in_button
    # The account's own wallet, which sends when the tab holds several of the
    # account's wallets and Privy names none (assets/js/privy/wallet_choice.ts).
    assert page =~ ~s(data-account-wallet="#{@made}")
  end

  test "a sign-in step without the token the CSRF step gave is refused", %{
    key: key,
    linked: linked
  } do
    started = get(browser(), "/auth/csrf")

    assert_error_sent 403, fn ->
      post_proof(started, key, did("no-token"), linked, "not-the-token")
    end
  end

  test "an email sign-in before Privy made its wallet is refused, and nothing is saved", %{
    key: key
  } do
    did = did("no-wallet")
    refused = sign_in(browser(), key, did, [@email])

    assert %{
             "error" => %{
               "code" => "unauthorized",
               "message" => "This sign-in couldn't be confirmed.",
               "hint" => "Sign in again."
             }
           } = json_response(refused, 401)

    assert Identity.get_profile_by_privy_user_id!(did) == nil
    assert RegentIdentity.profile_id("test-app", did) == {:ok, nil}
    assert signed_in_as(refused) == nil
    assert refused |> recycle([]) |> get("/account") |> html_response(200) =~ @sign_in_button
  end

  test "at the open address email is the only sign-in choice and no wallet is named",
       %{key: key, linked: linked} do
    assert build_conn() |> on_open() |> get("/account") |> html_response(200) =~
             ~s(<meta name="privy-sign-in" content="email">)

    refute build_conn() |> get("/account") |> html_response(200) =~ ~s(name="privy-sign-in")

    signed_in = sign_in(browser(&on_open/1), key, did("open-email"), linked)
    assert json_response(signed_in, 200) == %{"authenticated" => true}

    page = signed_in |> recycle([]) |> get("/account") |> html_response(200)
    refute page =~ @sign_in_button
    refute page =~ "data-account-wallet"

    refused = sign_in(browser(&on_open/1), key, did("open-no-wallet"), [@email])

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(refused, 401)
    refute refused.resp_body =~ ~r/wallet|payment|patchbay\.help/i
  end

  test "a wallet sign-in keeps the person's own wallet after Privy makes theirs", %{key: key} do
    did = did("own-wallet")
    first = sign_in(browser(), key, did, [wallet(@own, 2_000, "metamask")])

    signed_in =
      sign_in(first, key, did, [wallet(@own, 2_000, "metamask"), wallet(@made, 2_001, "privy")])

    assert json_response(signed_in, 200)
    assert Identity.get_profile_by_privy_user_id!(did).wallet_address == @own

    assert signed_in |> recycle([]) |> get("/account") |> html_response(200) =~
             ~s(data-account-wallet="#{@own}")
  end

  test "signing in again from a tab another tab has signed in since is refused, and the browser stays signed in",
       %{key: key, linked: linked} do
    did = did("two-tabs")
    first = sign_in(browser(), key, did, linked)
    behind = first |> recycle([]) |> get("/auth/csrf")
    ahead = sign_in(first, key, did, linked)

    stale = post_proof(behind, key, did, linked, json_response(behind, 200)["csrf_token"])

    assert %{"error" => %{"code" => "session_superseded"}} = json_response(stale, 409)
    refute Map.has_key?(stale.resp_cookies, @cookie)
    assert signed_in_as(ahead).privy_user_id == did
  end

  test "signing in as someone else ends the first sign-in, and the next try signs in the second",
       %{key: key, linked: linked} do
    first = sign_in(browser(), key, did("first"), linked)
    second = did("second")

    switched = sign_in(first, key, second, linked)

    assert %{"error" => %{"code" => "account_switch_required"}} = json_response(switched, 409)
    assert signed_in_as(switched) == nil
    assert signed_in_as(first) == nil

    signed_in = sign_in(switched, key, second, linked)
    assert json_response(signed_in, 200) == %{"authenticated" => true}
    assert signed_in_as(signed_in).privy_user_id == second
  end

  test "signing out ends the sign-in for good", %{key: key, linked: linked} do
    signed_in = sign_in(browser(), key, did("sign-out"), linked)
    signed_out = signed_in |> recycle([]) |> delete("/auth/privy/session")

    assert json_response(signed_out, 200) == %{"ok" => true}
    assert signed_in_as(signed_out) == nil
    assert signed_in_as(signed_in) == nil
  end

  # A wrong or missing Privy setting is the site's fault, not the browser's: the
  # sign-in step answers "try again" and judges nothing, so a release with a bad
  # setting never signs out the people whose pages refresh their sign-in.
  test "a sign-in step the site cannot check answers try again and leaves the browser signed in",
       %{key: key, linked: linked} do
    did = did("settings")
    signed_in = sign_in(browser(), key, did, linked)
    privy = Application.fetch_env!(:patchbay, :privy)

    # A key that is missing, and one that is there but cannot be read.
    for wrong <- [nil, "-----BEGIN PUBLIC KEY-----\nnot a key\n-----END PUBLIC KEY-----"] do
      Application.put_env(:patchbay, :privy, Keyword.put(privy, :verification_key, wrong))
      refreshed = sign_in(signed_in, key, did, linked)

      assert %{"error" => %{"code" => "sign_in_unavailable"}} = json_response(refreshed, 503)
      assert signed_in_as(refreshed).privy_user_id == did
    end
  end

  # Sean, 9 Nov 2026 ("100. a"): a suspended person cannot sign in on the web,
  # and every live web sign-in they hold ends. Only Patchbay's staff
  # suspend and reinstate.
  describe "a suspended person" do
    test "is refused at sign-in and stays signed out", %{key: key, linked: linked} do
      did = did("suspended")
      signed_in = sign_in(browser(), key, did, linked)
      assert json_response(signed_in, 200)
      {:ok, _suspended} = Identity.suspend_profile(profile(did), "Spam", actor: %{role: :system})

      refused = sign_in(signed_in, key, did, linked)

      assert %{"error" => %{"code" => "suspended"}} = json_response(refused, 403)
      assert signed_in_as(refused) == nil
      assert refused |> recycle([]) |> get("/account") |> html_response(200) =~ @sign_in_button
    end

    test "loses every live sign-in, open pages included, and the same browser signs in afresh once reinstated",
         %{key: key, linked: linked} do
      did = did("cut-off")
      signed_in = sign_in(browser(), key, did, linked)
      {:ok, page, _html} = live(recycle(signed_in, []), "/account")
      refute has_element?(page, "#account-signed-out")

      {:ok, _suspended} = Identity.suspend_profile(profile(did), "Spam", actor: %{role: :system})

      assert signed_in_as(signed_in) == nil
      send(page.pid, :agents_changed)
      assert has_element?(page, "#account-signed-out")

      {:ok, _reinstated} =
        Identity.reinstate_profile(profile(did), "Appeal upheld", actor: %{role: :system})

      assert signed_in_as(signed_in) == nil

      next_second()
      ended = sign_in(signed_in, key, did, linked)
      assert %{"error" => %{"code" => "session_reset_required"}} = json_response(ended, 409)

      fresh = sign_in(ended, key, did, linked)
      assert json_response(fresh, 200) == %{"authenticated" => true}
      assert signed_in_as(fresh).privy_user_id == did
    end
  end

  defp profile(did), do: Identity.get_profile_by_privy_user_id!(did)

  defp did(name), do: "did:privy:#{name}-#{System.unique_integer([:positive])}"

  # A sign-in made in the same second as a suspension stays ended with it.
  defp next_second, do: Process.sleep(1_001 - rem(System.os_time(:millisecond), 1_000))

  # A browser of its own, at an address of its own, so the new sessions other
  # tests start are not counted against it. Each next request keeps both
  # (`recycle/2`).
  defp browser(at \\ & &1) do
    n = System.unique_integer([:positive])
    build_conn() |> at.() |> Map.put(:remote_ip, {10, 11, rem(div(n, 256), 256), rem(n, 256)})
  end

  defp accepting(conn, nil), do: conn
  defp accepting(conn, type), do: put_req_header(conn, "accept", type)

  # Who the cookie `previous` left signs in, as a page read with it sees.
  defp signed_in_as(previous),
    do:
      previous
      |> recycle([])
      |> get("/auth/session")
      |> Map.fetch!(:assigns)
      |> Map.fetch!(:current_profile)

  # The browser's steps after `previous`: the CSRF step, then the sign-in step
  # with the token it gave.
  defp sign_in(previous, key, did, linked_accounts) do
    csrf = previous |> recycle([]) |> get("/auth/csrf")
    post_proof(csrf, key, did, linked_accounts, json_response(csrf, 200)["csrf_token"])
  end

  defp post_proof(previous, key, did, linked_accounts, token) do
    proof = proof(key, did, linked_accounts)

    previous
    |> recycle([])
    |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
    |> put_req_header("x-csrf-token", token)
    |> put_req_header("authorization", "Bearer " <> proof.access)
    |> put_req_header("privy-id-token", proof.identity)
    |> post("/auth/privy/session")
  end

  defp wallet(address, verified_at, client),
    do: %{
      "type" => "wallet",
      "address" => address,
      "chain_type" => "ethereum",
      "wallet_client_type" => client,
      "lv" => verified_at
    }

  defp proof(key, did, linked_accounts) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "aud" => "test-app",
      "sub" => did,
      "iat" => now - 1,
      "exp" => now + 600,
      "sid" => did
    }

    sign = fn claims ->
      key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact() |> elem(1)
    end

    %{
      access: sign.(claims),
      identity: sign.(Map.put(claims, "linked_accounts", Jason.encode!(linked_accounts)))
    }
  end
end
