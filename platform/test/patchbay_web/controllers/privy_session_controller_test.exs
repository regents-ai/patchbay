defmodule PatchbayWeb.PrivySessionControllerTest do
  # Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
  # Privy makes every person an Ethereum wallet when they sign in; the page hands
  # the tokens over only once it exists, and the server still refuses a Privy
  # session with no wallet. This signs in through the site's own sign-in step, as
  # the browser does, with tokens signed as Privy signs them. Adapted from
  # ash-template's sign_in_wallets_test.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import PatchbayWeb.ConnCase, only: [on_open: 1]

  @endpoint PatchbayWeb.Endpoint
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

    %{key: key}
  end

  test "an email sign-in with the wallet Privy made signs in, and the page shows it signed in",
       %{key: key} do
    did = "did:privy:email-#{System.unique_integer([:positive])}"
    signed_in = sign_in(key, did, [@email, wallet(@made, 1_001, "privy")])

    assert %{"human_linked" => true, "can_receive_usdc" => true} = json_response(signed_in, 200)
    assert Patchbay.Identity.get_profile_by_privy_user_id!(did).wallet_address == @made
    page = signed_in |> recycle([]) |> get("/account") |> html_response(200)
    refute page =~ @sign_in_button
    # The account's own wallet, which sends when the tab holds several of the
    # account's wallets and Privy names none (assets/js/privy/wallet_choice.ts).
    assert page =~ ~s(data-account-wallet="#{@made}")
  end

  test "an email sign-in before Privy made its wallet is still refused, and nothing is saved",
       %{key: key} do
    did = "did:privy:no-wallet-#{System.unique_integer([:positive])}"
    refused = sign_in(key, did, [@email])

    assert %{
             "error" => %{
               "code" => "no_wallet",
               "message" => "Your account has no wallet yet.",
               "hint" => "Sign in again to get one."
             }
           } = json_response(refused, 422)

    assert Patchbay.Identity.get_profile_by_privy_user_id!(did) == nil
    assert refused |> recycle([]) |> get("/account") |> html_response(200) =~ @sign_in_button
  end

  test "at the open address email is the only sign-in choice and no wallet is named", %{key: key} do
    assert build_conn() |> on_open() |> get("/account") |> html_response(200) =~
             ~s(<meta name="privy-sign-in" content="email">)

    refute build_conn() |> get("/account") |> html_response(200) =~ ~s(name="privy-sign-in")

    did = "did:privy:open-email-#{System.unique_integer([:positive])}"
    signed_in = sign_in(key, did, [@email, wallet(@made, 1_001, "privy")], &on_open/1)
    assert json_response(signed_in, 200)

    page = signed_in |> recycle([]) |> on_open() |> get("/account") |> html_response(200)
    refute page =~ @sign_in_button
    refute page =~ "data-account-wallet"

    refused =
      sign_in(
        key,
        "did:privy:open-no-wallet-#{System.unique_integer([:positive])}",
        [@email],
        &on_open/1
      )

    assert %{
             "error" => %{
               "code" => "no_wallet",
               "message" => "Your account is not ready yet.",
               "hint" => "Sign in again to finish."
             }
           } = json_response(refused, 422)
  end

  test "a wallet sign-in keeps the person's own wallet after Privy makes theirs", %{key: key} do
    did = "did:privy:own-wallet-#{System.unique_integer([:positive])}"
    sign_in(key, did, [wallet(@own, 2_000, "metamask")])

    signed_in =
      sign_in(key, did, [wallet(@own, 2_000, "metamask"), wallet(@made, 2_001, "privy")])

    assert json_response(signed_in, 200)
    assert Patchbay.Identity.get_profile_by_privy_user_id!(did).wallet_address == @own

    assert signed_in |> recycle([]) |> get("/account") |> html_response(200) =~
             ~s(data-account-wallet="#{@own}")
  end

  # The browser's steps: a page for its CSRF token, then Privy's two tokens on
  # the sign-in step.
  defp sign_in(key, did, linked_accounts, at \\ & &1) do
    page = build_conn() |> at.() |> get("/account")
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(page, 200))
    proof = proof(key, did, linked_accounts)

    page
    |> recycle()
    |> at.()
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-csrf-token", csrf)
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
