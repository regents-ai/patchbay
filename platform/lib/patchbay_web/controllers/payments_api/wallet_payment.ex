defmodule PatchbayWeb.PaymentsAPI.WalletPayment do
  @moduledoc """
  Paying from a page, with the signed-in account's own wallet.

  Patchbay writes the USDC transfer authorization itself, for one wallet, and
  hands it to the page as a `RegentChain.Review` with a single signature step.
  The page's wallet signs exactly that and sends back the signature alone.
  Patchbay rebuilds the same authorization, checks the signature came from
  that wallet, and only then puts the payment through `Purchase`.

  The only wallet that may sign is the page's active wallet when it is one of
  the account's own (`signer/2`). Nothing a page sends changes what is signed:
  the authorization is worked out again from the stored intent and the signer
  on every call.

  The authorization is the same every time for one intent and one wallet: it
  runs until the intent's terms expire, and its nonce comes from the intent's
  payment identifier and the wallet. A second press signs the same
  authorization, and USDC moves it at most once.
  """

  alias Patchbay.Payments.PaymentIntent
  alias PatchbayWeb.PaymentsAPI.Purchase
  alias RegentChain.Review
  alias X402.EIP3009

  @step "pay"
  @address ~r/\A0x[0-9a-fA-F]{40}\z/
  @signature ~r/\A0x[0-9a-fA-F]{130}\z/

  @transfer_types %{
    "EIP712Domain" => [
      %{"name" => "name", "type" => "string"},
      %{"name" => "version", "type" => "string"},
      %{"name" => "chainId", "type" => "uint256"},
      %{"name" => "verifyingContract", "type" => "address"}
    ],
    "TransferWithAuthorization" => [
      %{"name" => "from", "type" => "address"},
      %{"name" => "to", "type" => "address"},
      %{"name" => "value", "type" => "uint256"},
      %{"name" => "validAfter", "type" => "uint256"},
      %{"name" => "validBefore", "type" => "uint256"},
      %{"name" => "nonce", "type" => "bytes32"}
    ]
  }

  @doc "Every wallet on `profile`'s account, lowercased, the one tips settle to first."
  @spec linked(struct()) :: [String.t()]
  def linked(profile) do
    [profile.wallet_address | profile.wallet_addresses]
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc "The page's active wallet as it reported it, lowercased, or `nil`."
  @spec active_wallet(map()) :: String.t() | nil
  def active_wallet(%{"active_wallet" => address}) when is_binary(address) do
    if Regex.match?(@address, address), do: String.downcase(address)
  end

  def active_wallet(_params), do: nil

  @doc """
  The wallet that may sign: the page's `active` wallet when the account links
  it. With no active wallet, or one the account does not link, none may.
  """
  @spec signer([String.t()], String.t() | nil) :: String.t() | nil
  def signer(_linked, nil), do: nil
  def signer(linked, active), do: if(active in linked, do: active)

  @doc """
  The note beside the button while the page's wallet is not one of the
  account's, naming both.
  """
  @spec mismatch_note([String.t()], String.t()) :: String.t()
  def mismatch_note(linked, active) do
    "You're signed in with #{Enum.map_join(linked, " and ", &short/1)}, " <>
      "but your wallet app has #{short(active)} open."
  end

  @doc "What `signer` signs to pay for `found`, as the page is handed it."
  @spec review(PaymentIntent.t(), String.t()) :: Review.t()
  def review(found, signer) do
    Review.new(found.id, signer, chain(), [Review.signature(@step, typed_data(found, signer))])
  end

  @doc """
  The x402 payment `signer`'s `signature` makes for `found`, when it signs the
  review with `review_id`. The review is built again here, and the signature
  must recover to `signer` over Patchbay's own copy of what was signed.
  """
  @spec payment(PaymentIntent.t(), String.t(), map()) :: {:ok, map()} | {:refused, String.t()}
  def payment(found, signer, %{"review_id" => review_id, "signature" => signature})
      when is_binary(review_id) and is_binary(signature) do
    review = review(found, signer)
    %{typed_data: typed_data} = Review.find(review, @step)

    cond do
      review.id != review_id ->
        {:refused, "Those payment terms have changed since your wallet saw them."}

      not Regex.match?(@signature, signature) ->
        {:refused, "That signature could not be read."}

      recovered(typed_data, signature) != {:ok, signer} ->
        {:refused, "That signature is not from the wallet it was asked of."}

      true ->
        {:ok,
         %{
           "x402Version" => 2,
           "accepted" => Purchase.requirement(found),
           "payload" => %{
             "signature" => String.downcase(signature),
             "authorization" => typed_data["message"]
           },
           "extensions" => %{"paymentIdentifier" => Purchase.identifier_extension(found)}
         }}
    end
  end

  def payment(_found, _signer, _params), do: {:refused, "That signature could not be read."}

  defp typed_data(found, signer) do
    requirement = Purchase.requirement(found)
    {:ok, domain} = EIP3009.domain(requirement)

    %{
      "types" => @transfer_types,
      "primaryType" => "TransferWithAuthorization",
      "domain" => %{
        "name" => domain.name,
        "version" => domain.version,
        "chainId" => domain.chain_id,
        "verifyingContract" => String.downcase(domain.verifying_contract)
      },
      "message" => %{
        "from" => signer,
        "to" => String.downcase(requirement["payTo"]),
        "value" => requirement["amount"],
        "validAfter" => "0",
        "validBefore" => Integer.to_string(DateTime.to_unix(found.expires_at)),
        "nonce" => nonce(found, signer)
      }
    }
  end

  # One nonce for one intent and one wallet, so a repeat press signs the same
  # authorization rather than a second transfer.
  defp nonce(found, "0x" <> hex) do
    "0x" <>
      Base.encode16(
        ExKeccak.hash_256(found.payment_identifier <> Base.decode16!(hex, case: :lower)),
        case: :lower
      )
  end

  defp recovered(%{"domain" => domain, "message" => message}, signature) do
    with {:ok, digest} <- EIP3009.eip712_digest(domain, message) do
      EIP3009.recover_signer(digest, signature)
    end
  end

  defp chain, do: Application.fetch_env!(:patchbay, :payment_chain)

  defp short(address), do: RegentFormat.short_address(address)
end
