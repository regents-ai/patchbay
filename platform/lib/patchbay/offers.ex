defmodule Patchbay.Offers do
  @moduledoc """
  Agent offers: businesses pay to reach the agents that read a site's page on
  Patchbay, and Patchbay, the publisher, earns USDC for showing them.

  Money, leases, refunds and payouts live in Patchbay's `AgentOfferMarket` on
  Base (`contracts/src/AgentOfferMarket.sol`). What lives here is everything
  off the chain:

    * `Patchbay.Offers.Campaign`: an advertiser's offer, written once and
      named on the chain by its content hash.
    * `Patchbay.Offers.AdvertiserRule`: the advertisers Patchbay accepts and
      the ones it blocks.
    * `Patchbay.Offers.Placement`, `Termination`, `Lease` and `Settlement`:
      the market's own events, each written once as the chain gave it
      (`Patchbay.Offers.Scanner`), and `Patchbay.Offers.Cursor`, how far
      they have been read.
    * `Patchbay.Offers.Admission`: Patchbay's signature admitting one
      purchase, once the campaign is eligible for the slot.

  The whole feature is off while no market address is set
  (`config :patchbay, Patchbay.Offers, market_address: nil`, as in
  production): no page, no navigation, no reading job.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Offers.Campaign do
      define(:write_campaign, action: :write)
      define(:my_campaigns, action: :mine)
      define(:get_campaign, action: :read, get_by: [:id])
      define(:campaigns_by_ids, action: :by_campaign_ids, args: [:campaign_ids])
    end

    resource Patchbay.Offers.AdvertiserRule do
      define(:set_advertiser_rule, action: :set, args: [:wallet, :verdict])
      define(:remove_advertiser_rule, action: :destroy)
      define(:advertiser_rules, action: :for_wallets, args: [:wallets])
      define(:list_advertiser_rules, action: :read)
    end

    resource Patchbay.Offers.Placement do
      define(:record_placement, action: :record)
      define(:open_placements, action: :open, args: [:chain_id, :market])
      define(:get_placement, action: :read, get_by: [:chain_id, :market, :placement_id])
    end

    resource Patchbay.Offers.Termination do
      define(:record_termination, action: :record)
    end

    resource Patchbay.Offers.Lease do
      define(:record_lease, action: :record)
      define(:live_leases, action: :live, args: [:chain_id, :market])
    end

    resource Patchbay.Offers.Settlement do
      define(:record_settlement, action: :record)
    end

    resource Patchbay.Offers.Cursor do
      define(:get_cursor, action: :read, get_by: [:chain_id, :market], not_found_error?: false)
      define(:open_cursor, action: :open)
      define(:advance_cursor, action: :advance)
      define(:stop_cursor, action: :stop, args: [:block])
      define(:clear_cursor, action: :clear)
    end
  end

  @doc "The market's settings (`config :patchbay, Patchbay.Offers`)."
  @spec settings() :: keyword()
  def settings, do: Application.fetch_env!(:patchbay, __MODULE__)

  @doc "True when a market is set, which turns the whole feature on."
  @spec enabled?() :: boolean()
  def enabled?, do: market() != nil

  @doc "The market's address, lowercase, or nil when none is set."
  @spec market() :: String.t() | nil
  def market, do: settings()[:market_address]

  @doc """
  The chain the market is on, as a wallet step names it: its id, its name and
  the public address a wallet adds it with.
  """
  @spec chain() :: %{chain_id: pos_integer(), name: String.t(), rpc_url: String.t()}
  def chain do
    settings = settings()

    %{
      chain_id: settings[:chain_id],
      name: settings[:chain_name],
      rpc_url: settings[:wallet_rpc_url]
    }
  end

  @doc "The USDC token the market is paid in."
  @spec usdc() :: String.t()
  def usdc, do: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  @doc "The block the market was created in; nothing before it is read."
  @spec from_block() :: non_neg_integer()
  def from_block, do: settings()[:from_block]

  @doc """
  The hash of Patchbay's admission policy as the market names it. A
  placement created under any other policy is never admitted.
  """
  @spec policy_hash() :: String.t()
  def policy_hash, do: hash(settings()[:policy])

  @doc "keccak256 of `text`, as lowercase `0x` hex."
  @spec hash(binary()) :: String.t()
  def hash(text), do: "0x" <> Base.encode16(ExKeccak.hash_256(text), case: :lower)

  @doc "The PubSub topic a page hears on when the market's record changes."
  @spec topic() :: String.t()
  def topic, do: "offers"
end
