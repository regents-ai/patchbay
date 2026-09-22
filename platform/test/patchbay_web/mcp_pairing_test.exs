defmodule PatchbayWeb.MCPPairingTest do
  @moduledoc """
  Pairing a wallet with a person over the hosted MCP door: the wallet signs
  typed data naming the code, so a signature pairs with that code's person
  and no other; a signature from another wallet pairs nothing; and once
  paired, the wallet shares the person's Patchbay Credits.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits

  setup do
    {key, address} = wallet()
    {other_key, _other_address} = wallet()

    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:mcp-pairing-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    %{key: key, address: address, other_key: other_key, person: person}
  end

  test "a wallet pairs by signing for the person's code, and shares their balance", c do
    {:ok, :credited} = Credits.record_card_purchase(c.person.id, 500, payment())
    {:ok, %{code: code}} = Pairing.issue(c.person)
    args = %{"code" => code, "wallet_address" => c.address}

    unsigned = call(c.conn, "pair_with_person", args)
    assert unsigned["isError"] == true

    %{"problem_code" => "signature_required", "challenge" => challenge, "typed_data" => typed} =
      unsigned["structuredContent"]

    # Before anything is signed, the agent is told whose code it is.
    assert unsigned["structuredContent"]["person"]["profile_id"] == c.person.public_id
    assert typed["primaryType"] == "PairWithPerson"
    assert typed["message"]["code"] == code
    assert typed["message"]["person"] == c.person.public_id
    assert String.downcase(typed["message"]["wallet"]) == String.downcase(c.address)

    forged = call(c.conn, "pair_with_person", signed(args, challenge, c.other_key, typed))
    assert forged["structuredContent"]["problem_code"] == "other_wallet"
    assert Pairing.agents(c.person) == []

    paired = call(c.conn, "pair_with_person", signed(args, challenge, c.key, typed))
    refute paired["isError"]

    assert %{
             "paired" => true,
             "person" => %{"profile_id" => public_id},
             "balance_credits" => "5.00"
           } =
             paired["structuredContent"]

    assert public_id == c.person.public_id
    assert [agent] = Pairing.agents(c.person)
    assert agent.wallet_address == String.downcase(c.address)
    assert Credits.balance_atomic(agent.id) == 5_000_000

    # The code is used up: a signature made before it was used pairs nothing,
    # and asking again gives nothing to sign.
    used = call(c.conn, "pair_with_person", signed(args, challenge, c.key, typed))
    assert %{"paired" => false, "problem_code" => "code_unknown"} = used["structuredContent"]

    again = call(c.conn, "pair_with_person", args)
    assert %{"paired" => false, "problem_code" => "code_unknown"} = again["structuredContent"]
    refute Map.has_key?(again["structuredContent"], "typed_data")
  end

  test "a signature for one code never pairs with another", c do
    {:ok, %{code: code}} = Pairing.issue(c.person)

    stranger =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:mcp-pairing-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("d", 40)
      })

    {:ok, %{code: stranger_code}} = Pairing.issue(stranger)

    args = %{"code" => code, "wallet_address" => c.address}

    %{"challenge" => challenge, "typed_data" => typed} =
      call(c.conn, "pair_with_person", args)["structuredContent"]

    swapped =
      call(
        c.conn,
        "pair_with_person",
        signed(%{args | "code" => stranger_code}, challenge, c.key, typed)
      )

    assert swapped["structuredContent"]["problem_code"] == "challenge_mismatch"
    assert Pairing.agents(stranger) == []
    assert Pairing.agents(c.person) == []
  end

  test "a code too long to be one, or unknown, or half a proof, is refused before anything is signed",
       c do
    unknown =
      call(c.conn, "pair_with_person", %{"code" => "ABCDE-FGHJK", "wallet_address" => c.address})

    assert %{"paired" => false, "problem_code" => "code_unknown"} = unknown["structuredContent"]

    long =
      call(c.conn, "pair_with_person", %{
        "code" => String.duplicate("A", 65),
        "wallet_address" => c.address
      })

    assert %{"problem_code" => "invalid", "errors" => [_message]} = long["structuredContent"]

    {:ok, %{code: code}} = Pairing.issue(c.person)

    half =
      call(c.conn, "pair_with_person", %{
        "code" => code,
        "wallet_address" => c.address,
        "challenge" => "only one of the two"
      })

    assert half["structuredContent"]["problem_code"] == "invalid"
  end

  defp signed(args, challenge, key, typed),
    do: Map.merge(args, %{"challenge" => challenge, "signature" => sign_typed(key, typed)})

  defp call(conn, name, arguments) do
    %{"result" => result} =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{"name" => name, "arguments" => arguments}
        })
      )
      |> json_response(200)

    result
  end

  defp payment, do: "pi_" <> Ecto.UUID.generate()

  defp wallet do
    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    {key, Siwa.EvmPersonalSign.public_key_to_address(public)}
  end

  # Signs the typed data exactly as the tool handed it out, as a wallet would:
  # the chain id travels as a decimal string in EIP-712 JSON and is a number
  # when hashed.
  defp sign_typed(key, typed_data) do
    domain = typed_data["domain"]

    Ethers.TypedData.new!(
      types: Map.delete(typed_data["types"], "EIP712Domain"),
      primary_type: typed_data["primaryType"],
      domain: [
        name: domain["name"],
        version: domain["version"],
        chain_id: String.to_integer(domain["chainId"])
      ],
      message: typed_data["message"]
    )
    |> Ethers.sign_typed_data!(signer: Ethers.Signer.Local, signer_opts: [private_key: key])
  end
end
