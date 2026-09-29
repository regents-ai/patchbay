defmodule PatchbayDev.LabFacilitator do
  @moduledoc """
  The payments lab's payment service. It answers the same `/verify` and
  `/settle` calls Coinbase's facilitator does, and settles on the lab's copy
  of Base: a relayer account sends the signed USDC `transferWithAuthorization`
  and the answer is what the chain did with it. A transfer the chain turns
  down is still sent, with gas the relayer sets itself, so it is mined as a
  failure and answered as one.
  """
  use PatchbayWeb, :controller

  alias PatchbayDev.PaymentsLab
  alias X402.EIP3009

  # Anvil's tenth account, which the lab uses for nothing else.
  @relayer "0xa0ee7a142d267c1f36714e4a8f75612f20a79720"
  @gas "0x30d40"
  @transfer "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"

  def verify(conn, %{"paymentPayload" => payload, "paymentRequirements" => requirements}) do
    case signer(payload, requirements) do
      {:ok, payer} -> json(conn, %{isValid: true, payer: payer})
      {:error, reason} -> json(conn, %{isValid: false, invalidReason: reason})
    end
  end

  def settle(conn, %{"paymentPayload" => payload, "paymentRequirements" => requirements}) do
    network = requirements["network"]

    with {:ok, payer} <- signer(payload, requirements),
         {:ok, hash} <- send_transfer(payload["payload"], requirements),
         {:ok, receipt} <- receipt(hash, 20) do
      answer = %{transaction: hash, network: network, payer: payer}

      case receipt["status"] do
        "0x1" ->
          json(conn, Map.put(answer, :success, true))

        _reverted ->
          json(conn, Map.merge(answer, %{success: false, errorReason: "transfer_reverted"}))
      end
    else
      {:error, reason} -> json(conn, %{success: false, errorReason: reason, network: network})
    end
  end

  # The wallet that signed the authorization, when it is the one it names.
  defp signer(
         %{"payload" => %{"authorization" => authorization, "signature" => signature}},
         requirements
       ) do
    with {:ok, domain} <- EIP3009.domain(requirements),
         {:ok, digest} <- EIP3009.eip712_digest(domain, authorization),
         {:ok, signer} <- EIP3009.recover_signer(digest, signature),
         true <- signer == String.downcase(authorization["from"]) do
      {:ok, signer}
    else
      _unsigned -> {:error, "invalid_signature"}
    end
  end

  defp send_transfer(%{"authorization" => a, "signature" => "0x" <> signature}, requirements) do
    <<r::binary-size(32), s::binary-size(32), v>> = Base.decode16!(signature, case: :mixed)

    data =
      RegentChain.Call.encode(@transfer, [
        a["from"],
        a["to"],
        String.to_integer(a["value"]),
        String.to_integer(a["validAfter"]),
        String.to_integer(a["validBefore"]),
        a["nonce"],
        v,
        hex(r),
        hex(s)
      ])

    transaction = %{from: @relayer, to: requirements["asset"], data: data, gas: @gas}

    case PaymentsLab.rpc("eth_sendTransaction", [transaction]) do
      {:ok, hash} -> {:ok, hash}
      {:error, %{"message" => message}} -> {:error, message}
    end
  end

  defp receipt(_hash, 0), do: {:error, "not_mined"}

  defp receipt(hash, reads) do
    case PaymentsLab.rpc("eth_getTransactionReceipt", [hash]) do
      {:ok, %{"status" => _status} = receipt} ->
        {:ok, receipt}

      _pending ->
        Process.sleep(250)
        receipt(hash, reads - 1)
    end
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
