defmodule Mix.Tasks.Patchbay.Offers do
  @shortdoc "Runs Patchbay's agent offers on this machine: the lab market, placements and advertisers"

  @moduledoc """
  Patchbay's publisher work for agent offers, in development only (the task
  is not in a release). Until there is a publisher page, this is how
  placements are made and advertisers accepted or blocked.

      mix patchbay.offers lab --rpc-url URL --env-file PATH
      mix patchbay.offers place SITE [FLOOR]
      mix patchbay.offers fund WALLET
      mix patchbay.offers accept WALLET
      mix patchbay.offers block WALLET
      mix patchbay.offers rules
      mix patchbay.offers clear-stop NEXT_BLOCK

  `lab` deploys a fresh market on the lab chain (`scripts/offers-lab.sh`
  calls it) and writes the settings the site starts with to the env file.
  `place` and `fund` act on the market the site is set to, and only on a lab
  chain: `place` creates a placement for a listed site at Patchbay's terms
  with a floor of FLOOR whole USDC (5 when not given), and `fund` mints lab
  USDC to a wallet. `accept` and `block` set Patchbay's rule on an advertiser
  wallet, and `rules` lists them. `clear-stop` lets the market's reading go on
  from NEXT_BLOCK after a person corrected its record.
  """

  use Mix.Task

  alias Patchbay.Offers
  alias PatchbayDev.OffersLab

  @system %{role: :system}

  @impl Mix.Task
  def run(["lab" | args]) do
    {opts, _rest} = OptionParser.parse!(args, strict: [rpc_url: :string, env_file: :string])
    rpc_url = Keyword.fetch!(opts, :rpc_url)
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    %{market: market, from_block: from_block} = OffersLab.deploy(rpc_url)

    File.write!(
      Keyword.fetch!(opts, :env_file),
      """
      export PATCHBAY_OFFERS_MARKET=#{market}
      export PATCHBAY_OFFERS_RPC_URL=#{rpc_url}
      export PATCHBAY_OFFERS_FROM_BLOCK=#{from_block}
      export PATCHBAY_OFFERS_PUBLISHER_KEY=#{OffersLab.publisher_key()}
      """
    )

    Mix.shell().info("Market #{market}, made in block #{from_block}.")
  end

  def run(["place", site | floor]) do
    start!()
    {:ok, origin} = Patchbay.Forum.Origin.normalize(site)
    floor = floor |> List.first("5") |> String.to_integer()
    OffersLab.place!(Offers.chain().rpc_url, Offers.market(), origin, floor)
    Offers.Watch.refresh()
    Mix.shell().info("Placement made for #{origin}.")
  end

  def run(["fund", wallet]) do
    start!()
    OffersLab.fund!(Offers.chain().rpc_url, String.downcase(wallet))
    Mix.shell().info("Sent 1,000 lab USDC to #{wallet}.")
  end

  def run([verdict, wallet]) when verdict in ["accept", "block"] do
    start!()
    verdict = if verdict == "accept", do: :accepted, else: :blocked
    Offers.set_advertiser_rule!(String.downcase(wallet), verdict, actor: @system)
    Mix.shell().info("#{wallet} is #{verdict}.")
  end

  def run(["rules"]) do
    start!()

    for rule <- Offers.list_advertiser_rules!(actor: @system),
        do: Mix.shell().info("#{rule.wallet} #{rule.verdict}")
  end

  def run(["clear-stop", next_block]) do
    start!()
    cursor = Offers.get_cursor!(Offers.chain().chain_id, Offers.market())

    Offers.clear_cursor!(cursor, %{next_block: String.to_integer(next_block)}, actor: @system)
    Offers.Watch.refresh()
    Mix.shell().info("Reading goes on from block #{next_block}.")
  end

  def run(_args), do: Mix.raise("Usage: see mix help patchbay.offers")

  defp start! do
    Mix.Task.run("app.start")

    Offers.enabled?() or
      Mix.raise("No market is set: start the lab and source its env file first.")
  end
end
