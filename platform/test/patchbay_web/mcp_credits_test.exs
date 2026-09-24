defmodule PatchbayWeb.MCPCreditsTest do
  @moduledoc """
  A paired agent paying from its person's Patchbay Credits over the hosted
  MCP door, on the credit ledger every other door writes: a spend needs the
  wallet's signature naming the purchase and its price, is taken once however
  often it is sent, never takes more than the balance holds, stops the moment
  the person unpairs the agent, and a bounty taken back returns to the
  balance that paid for it.
  """

  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits

  setup do
    old_escrow = Application.get_env(:patchbay, :escrow)
    Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("e", 40))
    on_exit(fn -> Application.put_env(:patchbay, :escrow, old_escrow) end)

    {key, address} = wallet()
    {other_key, _other_address} = wallet()

    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:mcp-credits-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    {:ok, :credited} =
      Credits.record_card_purchase(person.id, 1_000, "pi_" <> Ecto.UUID.generate())

    %{
      key: key,
      address: address,
      other_key: other_key,
      person: person,
      origin: "https://credits-#{Ecto.UUID.generate()}.invalid"
    }
  end

  test "an agent spends its person's credits once per signed purchase, and a bounty taken back returns to them",
       c do
    pair(c)
    report = report_args(c, "5.00")

    # The first call names the purchase and its price for the wallet to sign.
    unsigned = call(c.conn, "post_priority_report", report)

    %{"problem_code" => "signature_required", "challenge" => challenge, "typed_data" => typed} =
      unsigned["structuredContent"]

    assert typed["primaryType"] == "SpendCredits"
    assert typed["message"]["amountCredits"] == "5.00"

    # Only the agent's own wallet can spend for it.
    forged = call(c.conn, "post_priority_report", signed(report, challenge, c.other_key, typed))
    assert forged["structuredContent"]["problem_code"] == "other_wallet"
    assert Credits.balance_atomic(c.person.id) == 10_000_000

    paid = call(c.conn, "post_priority_report", signed(report, challenge, c.key, typed))
    refute paid["isError"]
    assert %{"status" => "applied", "paid_with" => "patchbay_credits"} = paid["structuredContent"]
    assert Credits.balance_atomic(c.person.id) == 5_000_000

    # Sent again, the same purchase answers the same report and takes nothing more.
    again = call(c.conn, "post_priority_report", signed(report, challenge, c.key, typed))
    assert again["structuredContent"]["report_id"] == paid["structuredContent"]["report_id"]
    assert Credits.balance_atomic(c.person.id) == 5_000_000

    assert [%{kind: :spend, amount_atomic: -5_000_000}, %{kind: :card_purchase}] =
             Credits.history(c.person)

    # More than the balance holds is refused and writes nothing.
    short = spend(c, report_args(c, "6.00"))
    assert %{"problem_code" => "credits_short", "balance_credits" => "5.00"} = short
    assert short["error"] =~ "The person it is paired with can add credits"
    assert Credits.balance_atomic(c.person.id) == 5_000_000

    # Once unpaired, the agent spends only its own balance, which is nothing.
    {:ok, _unpaired} = Pairing.unpair(c.person, agent(c).public_id)
    unpaired = spend(c, report_args(c, "1.00"))
    assert %{"problem_code" => "credits_short", "balance_credits" => "0.00"} = unpaired
    assert Credits.balance_atomic(c.person.id) == 5_000_000

    # Thirty days on, the bounty goes back to the balance that paid for it.
    report = Forum.get_report!(paid["structuredContent"]["report_id"])
    held_since(report, 31)
    args = %{"report_id" => report.id, "wallet_address" => c.address}

    %{"challenge" => challenge, "typed_data" => typed} =
      call(c.conn, "withdraw_priority_report", args)["structuredContent"]

    returned = call(c.conn, "withdraw_priority_report", signed(args, challenge, c.key, typed))
    assert returned["structuredContent"]["escrow_status"] == "refunded"
    assert Credits.balance_atomic(c.person.id) == 9_500_000
    assert Credits.balance_atomic(agent(c).id) == 0
  end

  defp pair(c) do
    {:ok, %{code: code}} = Pairing.issue(c.person)
    args = %{"code" => code, "wallet_address" => c.address}

    %{"challenge" => challenge, "typed_data" => typed} =
      call(c.conn, "pair_with_person", args)["structuredContent"]

    assert %{"paired" => true, "balance_credits" => "10.00"} =
             call(c.conn, "pair_with_person", signed(args, challenge, c.key, typed))[
               "structuredContent"
             ]
  end

  # Asks, signs what it is asked to sign, and answers what the paid call said.
  defp spend(c, args) do
    %{"challenge" => challenge, "typed_data" => typed} =
      call(c.conn, "post_priority_report", args)["structuredContent"]

    call(c.conn, "post_priority_report", signed(args, challenge, c.key, typed))[
      "structuredContent"
    ]
  end

  defp report_args(c, amount) do
    %{
      "origin" => c.origin,
      "tool_name" => "checkout",
      "verdict" => "verified_failure",
      "note" => "The cart never changed for #{amount}.",
      "amount_usdc" => amount,
      "wallet_address" => c.address,
      "pay_with" => "credits"
    }
  end

  defp agent(c), do: Identity.upsert_from_wallet!(%{wallet_address: c.address})

  # How long ago the bounty was held; the clock is the only thing a test
  # cannot wait thirty days for.
  defp held_since(report, days) do
    report
    |> Ecto.Changeset.change(escrow_funded_at: DateTime.add(DateTime.utc_now(), -days, :day))
    |> Patchbay.Repo.update!()
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

  defp wallet do
    key = :crypto.strong_rand_bytes(32)
    {:ok, public} = ExSecp256k1.create_public_key(key)
    {key, Siwa.EvmPersonalSign.public_key_to_address(public)}
  end

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
