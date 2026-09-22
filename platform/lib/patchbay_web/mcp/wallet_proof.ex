defmodule PatchbayWeb.MCP.WalletProof do
  @moduledoc """
  How a hosted MCP connection proves it speaks for a wallet.

  The hosted door carries no signed-in wallet. Paying for a report proves the
  wallet by the payment's own signature; accepting an answer to that report
  or asking its bounty back moves money without a payment, so the wallet is
  asked to sign for the exact action instead. The tool answers with EIP-712
  typed data naming the action, the report, the reply, the wallet and a
  challenge this server signed, good for ten minutes; the caller has any
  EIP-712 signer sign it and calls the tool again with the challenge and the
  signature. The signer recovered from the signature has to be the wallet
  named, and the challenge has to be this server's and unexpired, so a
  signature proves one action on one report by one wallet, and nothing else.

  Pairing an agent with a person is proven the same way, with its own typed
  data naming the code the person gave and that person's public profile id,
  so the wallet sees whose code it is signing for and a signature pairs with
  that person and no other.

  Nothing here holds a key or moves money: the wallet signs, this checks.
  """

  alias Patchbay.Payments.USDC
  alias PatchbayWeb.Endpoint

  @salt "mcp wallet proof"
  @max_age_seconds 10 * 60

  @domain_name "Patchbay"
  @domain_version "1"

  @types %{
    "WalletAction" => [
      %{name: "action", type: "string"},
      %{name: "reportId", type: "string"},
      %{name: "replyId", type: "string"},
      %{name: "wallet", type: "address"},
      %{name: "challenge", type: "string"}
    ],
    "PairWithPerson" => [
      %{name: "code", type: "string"},
      %{name: "person", type: "string"},
      %{name: "wallet", type: "address"},
      %{name: "challenge", type: "string"}
    ]
  }

  @typedoc "One action on one report, or pairing with one person's code, by one wallet."
  @type action ::
          %{
            action: String.t(),
            report_id: String.t(),
            reply_id: String.t(),
            wallet: String.t()
          }
          | %{action: String.t(), code: String.t(), person: String.t(), wallet: String.t()}

  @doc "How long a challenge stands, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc """
  A fresh challenge for `action`, and the typed data to sign, in the shape
  `eth_signTypedData_v4` takes.
  """
  @spec challenge(action()) :: %{challenge: String.t(), typed_data: map()}
  def challenge(action) do
    challenge = Phoenix.Token.sign(Endpoint, @salt, action)

    %{
      challenge: challenge,
      typed_data: action |> typed_data(challenge) |> Ethers.TypedData.to_eip712_json()
    }
  end

  @doc """
  Whether `signature` is `action`'s wallet signing the typed data this server
  issued as `challenge` for exactly this action.
  """
  @spec verify(action(), String.t(), String.t()) ::
          :ok
          | {:error,
             :challenge_expired | :challenge_mismatch | :signature_unreadable | :other_wallet}
  def verify(action, challenge, signature) do
    with :ok <- issued_for(action, challenge),
         {:ok, signer} <- signer(typed_data(action, challenge), signature) do
      if String.downcase(signer) == action.wallet, do: :ok, else: {:error, :other_wallet}
    end
  end

  defp issued_for(action, challenge) do
    case Phoenix.Token.verify(Endpoint, @salt, challenge, max_age: @max_age_seconds) do
      {:ok, ^action} -> :ok
      {:ok, _other_action} -> {:error, :challenge_mismatch}
      {:error, :expired} -> {:error, :challenge_expired}
      {:error, _invalid} -> {:error, :challenge_mismatch}
    end
  end

  defp signer(typed_data, signature) do
    case Ethers.TypedData.recover_signer(typed_data, signature) do
      "0x" <> _ = address -> {:ok, address}
      {:error, _reason} -> {:error, :signature_unreadable}
    end
  end

  defp typed_data(%{action: "pair_with_person"} = action, challenge) do
    typed("PairWithPerson", %{
      "code" => action.code,
      "person" => action.person,
      "wallet" => action.wallet,
      "challenge" => challenge
    })
  end

  defp typed_data(action, challenge) do
    typed("WalletAction", %{
      "action" => action.action,
      "reportId" => action.report_id,
      "replyId" => action.reply_id,
      "wallet" => action.wallet,
      "challenge" => challenge
    })
  end

  defp typed(primary_type, message) do
    {:ok, chain_id} = X402.EIP712.chain_id_from_caip2(USDC.network())

    Ethers.TypedData.new!(
      types: Map.take(@types, [primary_type]),
      primary_type: primary_type,
      domain: [name: @domain_name, version: @domain_version, chain_id: chain_id],
      message: message
    )
  end
end
