defmodule Patchbay.Offers.RuntimeSettingsTest do
  @moduledoc """
  Agent offers as a boot reads them from config/runtime.exs. In production the
  market, its first block and the publisher key switch offers on and add the
  market's five-minute read to the Oban cron, which queues the read; with none
  of them set offers stay off and nothing is queued; a malformed setting stops
  the boot, naming the setting and never a value. Development reads the same
  settings, with its lab chain's node.
  """

  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Offers
  alias Patchbay.Offers.{Publisher, ReadMarket, Watch}

  @market "0x00000000000000000000000000000000000000Ab"
  @key "0x" <> String.duplicate("1", 64)
  @base_node "https://base-node.example"
  @lab_node "http://127.0.0.1:58620"

  # What a production machine is started with besides offers: the settings
  # config/runtime.exs refuses to boot without, none of them real.
  @production %{
    "PATCHBAY_SHOWCASE" => "off",
    "PATCHBAY_DEPLOYMENT_ROLE" => "production",
    "DATABASE_POOLED_URL" =>
      "postgres://patchbay:not-a-password@direct.dzx6qo6xqzvojpv5.flympg.net/patchbay",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "patchbay.help",
    "PATCHBAY_OPEN_HOST" => "open.patchbay.help",
    "SOURCE_COMMIT" => "0000000",
    "FLY_IMAGE_REF" => "registry.fly.io/patchbay-regents:test",
    "BASE_RPC_URL" => @base_node
  }

  @offers %{
    "PATCHBAY_OFFERS_MARKET" => @market,
    "PATCHBAY_OFFERS_FROM_BLOCK" => "38000000",
    "PATCHBAY_OFFERS_PUBLISHER_KEY" => @key
  }

  describe "a production boot" do
    test "with the market, its first block and the key set, turns offers on and schedules the market's read" do
      # The lab chain's node is development's alone; production reads Base through its own node.
      booted = boot!(:prod, Map.put(@offers, "PATCHBAY_OFFERS_RPC_URL", @lab_node))

      settings = booted[:patchbay][Offers]
      assert settings[:market_address] == String.downcase(@market)
      assert settings[:from_block] == 38_000_000
      assert settings[:wallet_rpc_url] == "https://mainnet.base.org"
      assert booted[:patchbay][:chain_nodes][8453] == @base_node
      assert {"*/5 * * * *", Watch} in crontab(booted)

      run_with!(booted)
      assert Offers.enabled?()
      assert Publisher.open?()

      assert :ok = perform_job(Watch, %{})

      assert_enqueued(
        worker: ReadMarket,
        queue: :offer_reads,
        args: %{chain_id: 8453, market: String.downcase(@market)}
      )
    end

    test "with none of them set, leaves offers off and queues nothing" do
      booted = boot!(:prod, %{})

      refute Enum.any?(crontab(booted), &match?({_schedule, Watch}, &1))

      run_with!(booted)
      refute Offers.enabled?()

      assert :ok = perform_job(Watch, %{})
      assert :ok = Watch.refresh()
      refute_enqueued(worker: ReadMarket)
    end

    test "with a malformed market address or block, stops naming the setting and never a value" do
      for {name, value} <- [
            {"PATCHBAY_OFFERS_MARKET", "0x1234"},
            {"PATCHBAY_OFFERS_MARKET", "patchbay.help"},
            {"PATCHBAY_OFFERS_FROM_BLOCK", "-1"},
            {"PATCHBAY_OFFERS_FROM_BLOCK", "38m"}
          ] do
        error = assert_raise RuntimeError, fn -> boot!(:prod, Map.put(@offers, name, value)) end

        assert error.message =~ name
        refute error.message =~ value
        refute error.message =~ @key
      end
    end
  end

  describe "a development boot" do
    test "reads the same settings and its lab chain's node" do
      booted = boot!(:dev, Map.put(@offers, "PATCHBAY_OFFERS_RPC_URL", @lab_node))

      settings = booted[:patchbay][Offers]
      assert settings[:market_address] == String.downcase(@market)
      assert settings[:from_block] == 38_000_000
      assert settings[:wallet_rpc_url] == @lab_node
      assert booted[:patchbay][:chain_nodes][8453] == @lab_node
      assert {"*/5 * * * *", Watch} in crontab(booted)
    end

    test "stops on a lab node that is not on this machine" do
      error =
        assert_raise RuntimeError, fn ->
          boot!(:dev, Map.put(@offers, "PATCHBAY_OFFERS_RPC_URL", @base_node))
        end

      assert error.message =~ "PATCHBAY_OFFERS_RPC_URL"
    end
  end

  # The settings a boot in `env` runs with, started with `variables` and the
  # settings production needs: config/runtime.exs read over the compiled ones.
  # Every variable read here is put back as it was.
  defp boot!(env, variables) do
    started = if env == :prod, do: Map.merge(@production, variables), else: variables

    names =
      Map.keys(@production) ++
        Map.keys(@offers) ++ ["PATCHBAY_OFFERS_RPC_URL", "PATCHBAY_RELEASE_COMMAND"]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    System.put_env(started)

    try do
      runtime = Config.Reader.read!("config/runtime.exs", env: env, imports: :disabled)
      Config.Reader.merge([patchbay: Application.get_all_env(:patchbay)], runtime)
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp crontab(booted), do: booted[:patchbay][Oban][:cron][:crontab]

  # The booted offer settings in place for the rest of the test.
  defp run_with!(booted) do
    original = Application.fetch_env!(:patchbay, Offers)
    on_exit(fn -> Application.put_env(:patchbay, Offers, original) end)
    Application.put_env(:patchbay, Offers, booted[:patchbay][Offers])
  end
end
