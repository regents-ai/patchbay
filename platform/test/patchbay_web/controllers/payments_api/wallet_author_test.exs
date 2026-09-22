defmodule PatchbayWeb.PaymentsAPI.WalletAuthorTest do
  use PatchbayWeb.ConnCase, async: false
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias PatchbayWeb.Plugs.{CurrentProfile, WalletAuthor}

  @address "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "wallet author is separate, stable, public and cannot become a human profile" do
    human =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:#{Ecto.UUID.generate()}",
        wallet_address: @address
      })

    wallet = Identity.upsert_from_wallet!(%{wallet_address: @address})
    again = Identity.upsert_from_wallet!(%{wallet_address: @address})
    assert again.id == wallet.id
    refute wallet.id == human.id
    assert wallet.authentication_origin == :wallet
    assert wallet.privy_user_id == nil
    assert wallet.human_name == nil
    assert wallet.wallet_chain_id == 8453
    assert CurrentProfile.signed_in_profile(%{"agent_profile_id" => wallet.id}) == nil
    assert {:error, _} = Identity.rename_agent(wallet, %{agent_name: "pretending"}, actor: wallet)

    assert {:error, _} =
             Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: human},
               actor: wallet
             )

    assert {:error, _} = Identity.upsert_from_privy(%{wallet_address: @address})

    assert {:ok, refreshed} =
             Identity.upsert_from_privy(%{
               privy_user_id: human.privy_user_id,
               wallet_address: @address
             })

    assert refreshed.id == human.id
    assert PatchbayWeb.AuthorJSON.author(wallet).human_linked == false
    body = get(build_conn(), "/agents/#{wallet.public_id}") |> html_response(200)
    assert body =~ "Signs in with its own wallet"
    refute body =~ "YOUR NAMES"
  end

  test "typed broker principal is required, without fallback to cookies or agent claims" do
    conn = post(build_conn(), "/api/agent/payment_intents", %{kind: "special_post", args: %{}})
    assert conn.status in [401, 503]
    conn = Plug.Test.conn(:post, "/api/agent/payment_intents", "{}")

    data = %{
      "verified" => true,
      "walletAddress" => @address,
      "chainId" => 8453,
      "principal" => %{
        "kind" => "wallet",
        "wallet_address" => @address,
        "chain_id" => 8453,
        "audience" => "patchbay"
      }
    }

    human =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:cookie-#{Ecto.UUID.generate()}",
        wallet_address: @address
      })

    cookie_conn = build_conn() |> Plug.Test.init_test_session(%{"agent_profile_id" => human.id})

    assert post(cookie_conn, "/api/agent/payment_intents", %{kind: "special_post", args: %{}}).status in [
             401,
             503
           ]

    conn =
      conn |> assign(:current_profile, human) |> assign(:forum_session_id, Ecto.UUID.generate())

    assert {:ok, accepted} = WalletAuthor.accept(conn, data, nil)
    refute accepted.assigns.current_profile.id == human.id
    assert accepted.assigns.forum_session_id == nil
    assert accepted.assigns.current_profile.authentication_origin == :wallet

    for invalid <- [
          Map.delete(data, "principal"),
          put_in(data, ["principal", "audience"], "regents"),
          put_in(data, ["principal", "kind"], "agent"),
          Map.put(data, "verified", false),
          put_in(data, ["principal", "chain_id"], 1),
          Map.put(data, "walletAddress", "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        ] do
      assert {:error, _} = WalletAuthor.accept(conn, invalid, nil)
    end

    profile = accepted.assigns.current_profile

    Patchbay.Repo.query!("UPDATE agent_profiles SET status='suspended' WHERE id=$1", [
      Ecto.UUID.dump!(profile.id)
    ])

    assert {:error, %{reason: :author_unavailable}} = WalletAuthor.accept(conn, data, nil)
    assert Identity.get_profile!(profile.id).status == :suspended
  end

  test "unsigned payment headers, tip authority and duplicate proof are refused before the broker" do
    conn =
      Plug.Test.conn(:post, "/api/agent/payment_intents/123/execute", "{}")
      |> Map.put(:body_params, %{})

    assert {:error, %{reason: :missing_signed_body}} = WalletAuthor.before_verify(conn, %{})

    conn =
      conn
      |> assign(:raw_body, "{}")
      |> put_private(:wallet_body_complete, true)
      |> put_req_header("content-type", "application/json")

    assert {:error, _} = WalletAuthor.before_verify(conn, %{"payment-signature" => "unsigned"})
    assert {:error, _} = WalletAuthor.before_verify(conn, %{"x-agent-token-id" => "1"})
    duplicate = %{conn | req_headers: [{"signature", "first"}, {"signature", "second"}]}
    assert {:error, _} = WalletAuthor.before_verify(duplicate, %{})

    tip = %{
      conn
      | path_info: ["api", "agent", "payment_intents"],
        body_params: %{"kind" => "agent_tip", "args" => %{}}
    }

    assert {:error, %{reason: :unsupported_action}} = WalletAuthor.before_verify(tip, %{})
  end

  test "a pairing request carries the code and nothing else" do
    conn =
      Plug.Test.conn(:post, "/api/agent/pairing", "{}")
      |> assign(:raw_body, "{}")
      |> put_private(:wallet_body_complete, true)
      |> put_req_header("content-type", "application/json")

    pairing = &%{conn | body_params: &1}

    assert {:ok, nil} = WalletAuthor.before_verify(pairing.(%{"code" => "ABCDE-FGHJK"}), %{})

    for refused <- [
          %{},
          %{"code" => ""},
          %{"code" => String.duplicate("A", 65)},
          %{"code" => 12_345},
          %{"code" => "ABCDE-FGHJK", "person" => "someone else"}
        ] do
      assert {:error, %{reason: :unsupported_action}} =
               WalletAuthor.before_verify(pairing.(refused), %{})
    end
  end
end
