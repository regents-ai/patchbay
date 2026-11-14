defmodule RegentNearIntentsTest do
  @moduledoc """
  The 1Click client against the service's own answers, saved on 14 Nov 2026
  (`test/support/near_intents/`): the token list and a dry quote for 5 USDC
  on Base. The deposit address, its deadline and the status answers follow
  the service's published API reference; no live call was made for them.
  """

  use ExUnit.Case, async: true

  @fixtures Path.expand("support/near_intents", __DIR__)
  @recipient "0x1111111111111111111111111111111111111111"

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  test "tokens/0 reads each asset with its id, symbol, chain, decimals and price" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v0/tokens"}
      Req.Test.json(conn, fixture("tokens.json"))
    end)

    assert {:ok, tokens} = RegentNearIntents.tokens()
    assert length(tokens) == length(fixture("tokens.json"))

    assert %{symbol: "wNEAR", blockchain: "near", decimals: 24, price: price} =
             Enum.find(tokens, &(&1.asset_id == "nep141:wrap.near"))

    assert is_number(price)
  end

  test "a dry quote asks for the one route and reads the NEAR it takes" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      assert {conn.method, conn.request_path} == {"POST", "/v0/quote"}
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      sent = Jason.decode!(body)

      assert Map.take(sent, ~w(dry swapType originAsset destinationAsset amount refundTo
                                 recipient depositType recipientType refundType)) == %{
               "dry" => true,
               "swapType" => "EXACT_OUTPUT",
               "originAsset" => "nep141:wrap.near",
               "destinationAsset" =>
                 "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near",
               "amount" => "5000000",
               "refundTo" => "test.near",
               "recipient" => @recipient,
               "depositType" => "ORIGIN_CHAIN",
               "recipientType" => "DESTINATION_CHAIN",
               "refundType" => "ORIGIN_CHAIN"
             }

      assert {:ok, _deadline, 0} = DateTime.from_iso8601(sent["deadline"])
      Req.Test.json(conn, fixture("quote_dry.json"))
    end)

    assert {:ok, quote} =
             RegentNearIntents.quote(%{
               usdc_amount: 5_000_000,
               recipient: @recipient,
               refund_to: "test.near",
               dry: true
             })

    assert %{
             amount_in: "1651313840569386417635746",
             amount_in_formatted: "1.651313840569386417635746",
             amount_out: "5000000",
             amount_out_formatted: "5.0",
             time_estimate_s: 24,
             deadline: nil,
             deposit_address: nil
           } = quote

    assert quote.raw == fixture("quote_dry.json")
  end

  test "a live quote carries its deposit address and when it closes" do
    answer =
      fixture("quote_dry.json")
      |> put_in(["quote", "depositAddress"], "deposit.near")
      |> put_in(["quote", "deadline"], "2026-11-14T23:00:00.000Z")

    Req.Test.stub(RegentNearIntents, &Req.Test.json(&1, answer))

    assert {:ok, %{deposit_address: "deposit.near", deadline: deadline}} =
             RegentNearIntents.quote(%{
               usdc_amount: 5_000_000,
               recipient: @recipient,
               refund_to: "test.near",
               dry: false
             })

    assert deadline == ~U[2026-11-14 23:00:00.000Z]
  end

  test "status/1 reads every state the service names, and both transactions" do
    for {status, state} <- [
          {"PENDING_DEPOSIT", :pending_deposit},
          {"INCOMPLETE_DEPOSIT", :pending_deposit},
          {"KNOWN_DEPOSIT_TX", :processing},
          {"PROCESSING", :processing},
          {"SUCCESS", :success},
          {"REFUNDED", :refunded},
          {"FAILED", :failed}
        ] do
      Req.Test.stub(RegentNearIntents, fn conn ->
        assert {conn.method, conn.request_path, conn.query_string} ==
                 {"GET", "/v0/status", "depositAddress=deposit.near"}

        Req.Test.json(conn, status_answer(status))
      end)

      assert {:ok, %{state: ^state, origin_tx: "near-tx", destination_tx: "0xbase"}} =
               RegentNearIntents.status("deposit.near")
    end
  end

  test "a swap with no transactions yet reads none" do
    answer =
      "PENDING_DEPOSIT"
      |> status_answer()
      |> put_in(["swapDetails", "originChainTxHashes"], [])
      |> put_in(["swapDetails", "destinationChainTxHashes"], [])

    Req.Test.stub(RegentNearIntents, &Req.Test.json(&1, answer))

    assert {:ok, %{state: :pending_deposit, origin_tx: nil, destination_tx: nil}} =
             RegentNearIntents.status("deposit.near")
  end

  test "refusals and failures answer reason and message" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{message: "refundTo is not valid"})
    end)

    assert {:error, %{reason: :bad_request, message: "refundTo is not valid"}} =
             RegentNearIntents.quote(%{
               usdc_amount: 5_000_000,
               recipient: @recipient,
               refund_to: "x",
               dry: true
             })

    Req.Test.stub(RegentNearIntents, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "Deposit address not found"})
    end)

    assert {:error, %{reason: :not_found}} = RegentNearIntents.status("nothing.near")

    Req.Test.stub(RegentNearIntents, &Plug.Conn.send_resp(&1, 503, ""))
    assert {:error, %{reason: :unavailable}} = RegentNearIntents.tokens()

    Req.Test.stub(RegentNearIntents, &Req.Test.json(&1, status_answer("SOMETHING_NEW")))
    assert {:error, %{reason: :unknown_status}} = RegentNearIntents.status("deposit.near")
  end

  # The status answer's shape, from the service's API reference.
  defp status_answer(status) do
    %{
      "correlationId" => "c",
      "quoteResponse" => fixture("quote_dry.json"),
      "status" => status,
      "updatedAt" => "2026-11-14T19:30:00.000Z",
      "swapDetails" => %{
        "intentHashes" => [],
        "nearTxHashes" => [],
        "originChainTxHashes" => [
          %{"hash" => "near-tx", "explorerUrl" => "https://nearblocks.io/txns/near-tx"}
        ],
        "destinationChainTxHashes" => [
          %{"hash" => "0xbase", "explorerUrl" => "https://basescan.org/tx/0xbase"}
        ]
      }
    }
  end
end
