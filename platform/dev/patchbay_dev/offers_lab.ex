defmodule PatchbayDev.OffersLab do
  @moduledoc """
  The agent offers lab: Patchbay's offer market on a lab chain on this
  machine, never anywhere else. `scripts/offers-lab.sh start` runs anvil as
  Base (chain 8453) and calls `start!/2`, and its `place` and `fund` call
  `place_site!/2` and `fund_wallet!/1`; the end-to-end test calls `deploy/1`
  and the rest directly.

  The factory refuses any chain but Base with Circle's USDC at its address, so
  the lab places a stand-in USDC (the contracts' `FreezableUSDC`, anyone may
  mint it) at that address with `anvil_setCode`, and a stand-in REGENT staking
  contract (`RecordingStaking`) beside it. Every transaction is sent from one
  of anvil's own unlocked accounts, so no key is used to deploy: account 0
  owns the factory, account 1 is Patchbay's publisher, account 2 its payout
  wallet, and accounts 3 and 4 are advertisers with 1,000 USDC each.

  Every function first checks that the address is a lab chain: http on this
  machine, a node that says it is anvil, serving chain 8453.
  """

  alias Patchbay.Offers.Contract
  alias RegentChain.{Abi, Call}

  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @accounts %{
    owner: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    publisher: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
    payout: "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
    advertiser: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
    rival: "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65"
  }
  # Anvil's account 1, as Foundry documents it: a test key, never a real one.
  @publisher_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @fee_bps 1_000
  @dollar 1_000_000

  @doc "Anvil's accounts the lab uses, by role."
  def accounts, do: @accounts

  @doc "The publisher's key: anvil's account 1, Foundry's published test key."
  def publisher_key, do: @publisher_key

  @doc """
  `scripts/offers-lab.sh start`: deploys a fresh market on the lab chain at
  `rpc_url` and writes the settings the site starts with to `env_file`.
  """
  def start!(rpc_url, env_file) do
    {:ok, _apps} = Application.ensure_all_started(:req)
    %{market: market, from_block: from_block} = deploy(rpc_url)

    File.write!(env_file, """
    export PATCHBAY_OFFERS_MARKET=#{market}
    export PATCHBAY_OFFERS_RPC_URL=#{rpc_url}
    export PATCHBAY_OFFERS_FROM_BLOCK=#{from_block}
    export PATCHBAY_OFFERS_PUBLISHER_KEY=#{@publisher_key}
    """)

    IO.puts("Market #{market}, made in block #{from_block}.")
  end

  @doc """
  `scripts/offers-lab.sh place SITE [FLOOR]`: a placement for the listed
  site on the market the site is set to, then a read of the market.
  """
  def place_site!(site, floor) do
    {:ok, origin} = Patchbay.Forum.Origin.normalize(site)

    place!(
      Patchbay.Offers.chain().rpc_url,
      Patchbay.Offers.market(),
      origin,
      String.to_integer(floor)
    )

    Patchbay.Offers.Watch.refresh()
    IO.puts("Placement made for #{origin}.")
  end

  @doc "`scripts/offers-lab.sh fund WALLET`: 1,000 stand-in USDC to `wallet`."
  def fund_wallet!(wallet) do
    fund!(Patchbay.Offers.chain().rpc_url, String.downcase(wallet))
    IO.puts("Sent 1,000 lab USDC to #{wallet}.")
  end

  @doc """
  Deploys a fresh factory and market on the lab chain at `rpc_url` and funds
  the two advertisers. Returns the market's address and the block it was
  made in.
  """
  def deploy(rpc_url) do
    lab!(rpc_url)

    usdc_stand_in = create!(rpc_url, "AgentOfferTestKit.sol/FreezableUSDC", [], [])

    rpc!(rpc_url, "anvil_setCode", [
      @usdc,
      rpc!(rpc_url, "eth_getCode", [usdc_stand_in, "latest"])
    ])

    staking = create!(rpc_url, "AgentOfferTestKit.sol/RecordingStaking", [:address], [bin(@usdc)])

    factory =
      create!(
        rpc_url,
        "AgentOfferFactory.sol/AgentOfferFactory",
        [:address, :address, :address, {:uint, 16}],
        [bin(@accounts.owner), bin(@accounts.publisher), bin(staking), @fee_bps]
      )

    receipt =
      send!(
        rpc_url,
        @accounts.publisher,
        factory,
        Call.encode("createMarket(address)", [@accounts.payout])
      )

    {:ok, bytes} =
      Abi.bytes(call!(rpc_url, factory, Call.encode("marketOf(address)", [@accounts.publisher])))

    {:ok, [market]} = Abi.decode(bytes, [:address])

    fund!(rpc_url, @accounts.advertiser)
    fund!(rpc_url, @accounts.rival)

    %{market: market, from_block: quantity(receipt["blockNumber"])}
  end

  @doc """
  Creates a placement for the listed site `origin` with Patchbay's own terms
  (3 slots, 72 hours, a 10% step) and a floor of `floor` whole USDC, sent by
  the publisher. Its address is the site's page, so its site can be read back.
  """
  def place!(rpc_url, market, origin, floor \\ 5) do
    lab!(rpc_url)

    data =
      Contract.create_placement(
        ExKeccak.hash_256(origin),
        {3, 72 * 3600, 1_000, floor * @dollar,
         ExKeccak.hash_256(Patchbay.Offers.settings()[:policy])},
        PatchbayWeb.Endpoint.url() <> "/" <> origin
      )

    send!(rpc_url, @accounts.publisher, market, Ethers.Utils.hex_encode(data.data))
  end

  @doc "Mints 1,000 stand-in USDC to `wallet`."
  def fund!(rpc_url, wallet) do
    lab!(rpc_url)

    send!(
      rpc_url,
      @accounts.owner,
      @usdc,
      Call.encode("mint(address,uint256)", [wallet, 1_000 * @dollar])
    )
  end

  @doc """
  Sends `data` to `to` from `from`, one of anvil's unlocked accounts, and
  returns the receipt, whatever its status.
  """
  def send(rpc_url, from, to, data) do
    lab!(rpc_url)
    rpc!(rpc_url, "eth_sendTransactionSync", [%{from: from, to: to, data: data}])
  end

  @doc "Moves the lab chain's clock on by `seconds` and makes a block."
  def wait!(rpc_url, seconds) do
    lab!(rpc_url)
    rpc!(rpc_url, "evm_increaseTime", [seconds])
    rpc!(rpc_url, "evm_mine", [])
  end

  @doc "One JSON-RPC request to the lab chain; `{:ok, result}` or `{:error, error}`."
  def rpc(rpc_url, method, params) do
    case Req.post(rpc_url,
           json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => error}}} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Raises unless `rpc_url` is a lab chain: anvil, on this machine, as Base."
  def lab!(rpc_url) do
    case URI.new(rpc_url) do
      {:ok, %URI{scheme: "http", host: host}} when host in ["127.0.0.1", "localhost"] -> :ok
      _other -> raise ArgumentError, "the offers lab runs only on a chain on this machine"
    end

    with {:ok, "anvil/" <> _version} <- rpc(rpc_url, "web3_clientVersion", []),
         {:ok, "0x2105"} <- rpc(rpc_url, "eth_chainId", []) do
      :ok
    else
      _other -> raise ArgumentError, "the offers lab runs only on anvil serving chain 8453"
    end
  end

  defp create!(rpc_url, artifact, types, args) do
    path = Path.expand("../../../contracts/out/#{artifact}.json", __DIR__)
    "0x" <> code = path |> File.read!() |> Jason.decode!() |> get_in(["bytecode", "object"])
    data = "0x" <> code <> Base.encode16(ABI.TypeEncoder.encode(args, types), case: :lower)
    receipt = rpc!(rpc_url, "eth_sendTransactionSync", [%{from: @accounts.owner, data: data}])
    "0x1" = receipt["status"]
    receipt["contractAddress"]
  end

  defp send!(rpc_url, from, to, data) do
    receipt = __MODULE__.send(rpc_url, from, to, data)
    "0x1" = receipt["status"]
    receipt
  end

  defp call!(rpc_url, to, data), do: rpc!(rpc_url, "eth_call", [%{to: to, data: data}, "latest"])

  defp rpc!(rpc_url, method, params) do
    {:ok, result} = rpc(rpc_url, method, params)
    result
  end

  defp bin("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp quantity("0x" <> hex), do: String.to_integer(hex, 16)
end
