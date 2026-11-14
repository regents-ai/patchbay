defmodule PatchbayWeb.ProfileAPITest do
  # A person's Public Display Name lives in the shared profile every Regent site
  # reads (`RegentIdentity.HTTP` at /api/v1/profile). It is read and changed for
  # the person signed in on this browser, a change only with the session's forms
  # token (`PatchbayWeb.Plugs.ProfileOwner`), and for nobody else. Signing in
  # gives the person their profile. People sign in through the site's own steps,
  # with tokens signed as Privy signs them. As ash-template's public_name_test.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Patchbay.Identity

  @endpoint PatchbayWeb.Endpoint
  @path "/api/v1/profile"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Patchbay.Repo, shared: true)
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    privy = Application.get_env(:patchbay, :privy, [])
    Application.put_env(:patchbay, :privy, app_id: "test-app", verification_key: pem)

    on_exit(fn ->
      Application.put_env(:patchbay, :privy, privy)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    %{key: key}
  end

  test "signing in gives the person their profile, whose name they set with the forms token",
       %{key: key} do
    did = did("named")
    {signed_in, token} = sign_in(browser(), key, did)

    assert {:ok, id} = RegentIdentity.profile_id("test-app", did)
    assert %{"profile_id" => ^id, "display_name" => nil} = read(signed_in)

    saved = change(signed_in, %{display_name: "Ada Lovelace"}, token)
    assert json_response(saved, 200)["profile"]["display_name"] == "Ada Lovelace"
    assert read(signed_in)["display_name"] == "Ada Lovelace"

    assert signed_in |> recycle([]) |> get("/account") |> html_response(200) =~
             ~s(value="Ada Lovelace")
  end

  test "a change without this session's forms token counts as signed out and changes nothing",
       %{key: key} do
    {signed_in, _token} = sign_in(browser(), key, did("forged"))
    {_elsewhere, other_token} = sign_in(browser(), key, did("elsewhere"))

    for token <- [nil, "not-a-token", other_token] do
      refused = change(signed_in, %{display_name: "Mallory"}, token)
      assert json_response(refused, 401)["error"]["code"] == "authentication_required"
    end

    assert read(signed_in)["display_name"] == nil
  end

  test "signed out, nothing is read or changed" do
    started = get(browser(), "/auth/csrf")
    token = json_response(started, 200)["csrf_token"]

    assert started |> recycle([]) |> get(@path) |> json_response(401) |> code() ==
             "authentication_required"

    assert started |> change(%{display_name: "Nobody"}, token) |> json_response(401) |> code() ==
             "authentication_required"

    refute started |> recycle([]) |> get("/account") |> html_response(200) =~
             "data-regent-profile"
  end

  test "once the sign-in has ended, its cookie and forms token read and change nothing",
       %{key: key} do
    {signed_in, token} = sign_in(browser(), key, did("ended"))
    assert signed_in |> recycle([]) |> delete("/auth/privy/session") |> json_response(200)

    refused(signed_in, token)
  end

  # A suspension ends every web sign-in the person holds.
  test "a suspended person's sign-in reads and changes nothing", %{key: key} do
    did = did("suspended")
    {signed_in, token} = sign_in(browser(), key, did)
    profile = Identity.get_profile_by_privy_user_id!(did)
    {:ok, _suspended} = Identity.suspend_profile(profile, "Spam", actor: %{role: :system})

    refused(signed_in, token)
  end

  test "a person signed in before sign-in gave profiles has none, and saves once they sign in again",
       %{key: key} do
    did = did("before")
    {signed_in, token} = sign_in(browser(), key, did)

    # Their sign-in from before this release: the session, and no shared profile.
    Ecto.Adapters.SQL.query!(
      Patchbay.Repo,
      "DELETE FROM regent_identity.profiles WHERE privy_user_id = $1",
      [did]
    )

    assert signed_in |> recycle([]) |> get(@path) |> json_response(404) |> code() ==
             "profile_not_created"

    assert signed_in |> change(%{display_name: "Ada"}, token) |> json_response(422) |> code() ==
             "invalid_profile_update"

    {again, token} = sign_in(signed_in, key, did)
    assert json_response(change(again, %{display_name: "Ada"}, token), 200)
    assert read(again)["display_name"] == "Ada"
  end

  defp read(signed_in),
    do: signed_in |> recycle([]) |> get(@path) |> json_response(200) |> Map.fetch!("profile")

  # The browser's cookie and forms token now count as signed out.
  defp refused(signed_in, token) do
    assert signed_in |> recycle([]) |> get(@path) |> json_response(401) |> code() ==
             "authentication_required"

    assert signed_in |> change(%{display_name: "Too late"}, token) |> json_response(401) |> code() ==
             "authentication_required"
  end

  # A browser's change, with the forms token it sends, if any. Phoenix's test
  # connection skips the forms token check; these keep it, as a browser's do.
  defp change(previous, body, token) do
    conn =
      previous
      |> recycle([])
      |> enforce_csrf()
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "x-csrf-token", token), else: conn
    patch(conn, @path, Jason.encode!(body))
  end

  defp code(body), do: body["error"]["code"]

  defp enforce_csrf(conn),
    do: Map.update!(conn, :private, &Map.delete(&1, :plug_skip_csrf_protection))

  defp did(name), do: "did:privy:#{name}-#{System.unique_integer([:positive])}"

  # A browser of its own, at an address of its own, so the sessions other tests
  # start are not counted against it.
  defp browser do
    n = System.unique_integer([:positive])
    build_conn() |> Map.put(:remote_ip, {10, 12, rem(div(n, 256), 256), rem(n, 256)})
  end

  # The browser's steps after `previous`: the CSRF step, Privy's two tokens on the
  # sign-in step, then the forms token the site's pages carry for the session
  # that step left.
  defp sign_in(previous, key, did) do
    csrf = previous |> recycle([]) |> get("/auth/csrf")
    proof = proof(key, did)

    signed_in =
      csrf
      |> recycle([])
      |> enforce_csrf()
      |> put_req_header("x-csrf-token", json_response(csrf, 200)["csrf_token"])
      |> put_req_header("authorization", "Bearer " <> proof.access)
      |> put_req_header("privy-id-token", proof.identity)
      |> post("/auth/privy/session")

    assert json_response(signed_in, 200) == %{"authenticated" => true}
    page = signed_in |> recycle([]) |> get("/auth/csrf")
    {page, json_response(page, 200)["csrf_token"]}
  end

  defp proof(key, did) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "aud" => "test-app",
      "sub" => did,
      "iat" => now - 1,
      "exp" => now + 600,
      "sid" => did
    }

    # Each person's own wallet, the one Privy made them.
    wallet = "0x" <> Base.encode16(binary_part(:crypto.hash(:sha256, did), 0, 20), case: :lower)

    linked = [
      %{
        "type" => "wallet",
        "address" => wallet,
        "chain_type" => "ethereum",
        "wallet_client_type" => "privy",
        "lv" => now - 1
      }
    ]

    sign = fn claims ->
      key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact() |> elem(1)
    end

    %{
      access: sign.(claims),
      identity: sign.(Map.put(claims, "linked_accounts", Jason.encode!(linked)))
    }
  end
end
