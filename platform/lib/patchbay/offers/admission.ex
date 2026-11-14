defmodule Patchbay.Offers.Admission do
  @moduledoc """
  Patchbay's admission of one purchase: the publisher's EIP-712 signature the
  market checks before it takes a buyer's money, over exactly the placement,
  slot, site, buyer, campaign, policy, amount, the slot's lease nonce the buyer
  saw, and a deadline.

  Patchbay admits a purchase only for a signed-in person, for a campaign their
  account wrote, paid from that campaign's own wallet, when the campaign is
  eligible for the placement (`Patchbay.Offers.Eligibility`): approved by
  Patchbay and never pulled, from an advertiser it accepts, in a pool the
  placement shows from. Patchbay's side of that is read as the system. The
  admission lasts ten minutes. While no publisher key is set, buying is
  closed.

  The key is read from `config :patchbay, Patchbay.Offers` and nowhere else,
  and nothing here writes it anywhere: not into a log, an error or a result.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.{Campaign, Eligibility, Publisher}

  @lifetime_seconds 600

  @permit_type [
    %{"name" => "placementId", "type" => "uint256"},
    %{"name" => "slot", "type" => "uint16"},
    %{"name" => "sourceId", "type" => "bytes32"},
    %{"name" => "buyer", "type" => "address"},
    %{"name" => "campaignId", "type" => "bytes32"},
    %{"name" => "policyHash", "type" => "bytes32"},
    %{"name" => "amountUSDC", "type" => "uint128"},
    %{"name" => "expectedLeaseNonce", "type" => "uint64"},
    %{"name" => "deadline", "type" => "uint64"}
  ]

  @domain_type [
    %{"name" => "name", "type" => "string"},
    %{"name" => "version", "type" => "string"},
    %{"name" => "chainId", "type" => "uint256"},
    %{"name" => "verifyingContract", "type" => "address"}
  ]

  @type purchase :: %{
          placement_id: pos_integer(),
          slot: non_neg_integer(),
          campaign_id: String.t(),
          amount: pos_integer(),
          expected_nonce: non_neg_integer(),
          deadline: pos_integer()
        }

  @type refusal ::
          :closed
          | :not_your_campaign
          | :not_your_wallet
          | :unknown_placement
          | :unknown_slot
          | Eligibility.reason()

  @doc """
  Admits `actor`'s purchase of `slot` in placement `placement_id` for
  `campaign`, paying `amount` USDC base units, against the slot's lease
  nonce `expected_nonce`. Returns the purchase as the market takes it, its
  buyer, and the signature.
  """
  @spec admit(
          map(),
          Campaign.t() | map(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, %{purchase: purchase(), buyer: String.t(), permit: String.t()}}
          | {:error, refusal()}
  def admit(actor, campaign, placement_id, slot, amount, expected_nonce) do
    with {:ok, publisher, placement} <- admissible(actor, campaign, placement_id, slot) do
      purchase = %{
        placement_id: placement_id,
        slot: slot,
        campaign_id: campaign.campaign_id,
        amount: amount,
        expected_nonce: expected_nonce,
        deadline: System.os_time(:second) + @lifetime_seconds
      }

      buyer = campaign.advertiser

      {:ok, digest} =
        purchase |> typed_data(placement.source_id, buyer) |> RegentChain.Typed.digest()

      {:ok, %{purchase: purchase, buyer: buyer, permit: Publisher.sign(publisher, digest)}}
    end
  end

  @doc """
  Whether Patchbay would admit `actor`'s purchase of `slot` in placement
  `placement_id` for `campaign`, by the same rules as `admit/6`, without
  signing anything: `:ok`, or the first refusal.
  """
  @spec check(map(), Campaign.t() | map(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, refusal()}
  def check(actor, campaign, placement_id, slot) do
    with {:ok, _publisher, _placement} <- admissible(actor, campaign, placement_id, slot),
         do: :ok
  end

  defp admissible(actor, campaign, placement_id, slot) do
    with {:ok, publisher} <- Publisher.signer(),
         :ok <- owned(actor, campaign),
         {:ok, placement} <- placement(placement_id, slot),
         :ok <- eligible(actor, campaign, placement),
         do: {:ok, publisher, placement}
  end

  @doc """
  The EIP-712 typed data Patchbay signs for `purchase` by `buyer` in a
  placement on the site `source_id`, as `eth_signTypedData_v4` takes it.
  """
  @spec typed_data(purchase(), String.t(), String.t()) :: map()
  def typed_data(purchase, source_id, buyer) do
    chain = Offers.chain()

    %{
      "types" => %{"EIP712Domain" => @domain_type, "EligibilityPermit" => @permit_type},
      "primaryType" => "EligibilityPermit",
      "domain" => %{
        "name" => "AgentOfferMarket",
        "version" => "1",
        "chainId" => chain.chain_id,
        "verifyingContract" => Offers.market()
      },
      "message" => %{
        "placementId" => purchase.placement_id,
        "slot" => purchase.slot,
        "sourceId" => source_id,
        "buyer" => buyer,
        "campaignId" => purchase.campaign_id,
        "policyHash" => Offers.policy_hash(),
        "amountUSDC" => purchase.amount,
        "expectedLeaseNonce" => purchase.expected_nonce,
        "deadline" => purchase.deadline
      }
    }
  end

  defp owned(actor, campaign) do
    cond do
      campaign.agent_profile_id != actor.id -> {:error, :not_your_campaign}
      campaign.advertiser not in Campaign.OwnWallet.wallets(actor) -> {:error, :not_your_wallet}
      true -> :ok
    end
  end

  defp placement(placement_id, slot) do
    chain_id = Offers.chain().chain_id

    case Offers.get_placement(chain_id, Offers.market(), placement_id, not_found_error?: false) do
      {:ok, nil} -> {:error, :unknown_placement}
      {:ok, %{capacity: capacity}} when slot >= capacity -> {:error, :unknown_slot}
      {:ok, placement} -> {:ok, placement}
    end
  end

  # Where the campaign stands is read again, so a pull made a moment ago counts.
  defp eligible(actor, campaign, placement) do
    campaign = Ash.load!(campaign, [:review], actor: actor)
    Eligibility.check(campaign, placement, Eligibility.terms([placement], [campaign]))
  end
end
