defmodule Patchbay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Every outbound TLS connection trusts castore's list, not the operating
    # system's: castore drops a compromised root as soon as Mozilla does, which a
    # Debian image can lag by weeks. Req, Finch and Mint read this list through
    # `:public_key.cacerts_get/0`, so it is loaded before anything connects.
    :ok = :public_key.cacerts_load(CAStore.file_path())
    :ok = RegentOAuth.configure(Patchbay.OAuth)
    :ok = RegentMCPAgents.configure!()

    # Attached before the endpoint so the first browser event of a boot is logged.
    :ok = PatchbayWeb.VisitLog.Events.attach()
    :ok = Patchbay.OperatorWallet.attach()

    children =
      [
        PatchbayWeb.Telemetry,
        Patchbay.Repo,
        if(RegentOAuth.enabled?(), do: RegentOAuth.Repo),
        {DNSCluster, query: Application.get_env(:patchbay, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Patchbay.PubSub},
        # The figures every visitor sees alike, then the readers that keep them.
        # Each reader stores its first reading as it starts, so every key is
        # there before the endpoint below serves a page.
        Patchbay.SharedReading,
        wallet_bench_board(),
        # The Wallet Bench's filtered boards, built four at a time.
        Patchbay.WalletBench.Board.builds(),
        # Each paired agent's sign-in service reading, kept five minutes.
        Patchbay.Agents.ActivityReading,
        # The home page's board figures, kept a minute.
        Patchbay.Forum.BoardActivity,
        # Each question list's thread count, kept a minute.
        Patchbay.Forum.FeedCount,
        # Each Wallet Bench run's record from Techtree, kept five minutes.
        Patchbay.WalletBench.RunRecords,
        # Each agent's reading for an open account menu, unlinked from the page.
        {Task.Supervisor, name: Patchbay.Agents.Reads},
        # After the repository and PubSub: a Credits balance changed or a
        # pairing made or ended on any Regent site reaches the pages showing it.
        Patchbay.SharedChanges,
        RegentPayments.Supervisor,
        # The paid-call test page's record of payments it has already seen.
        PatchbayWeb.Plugs.X402Test.replays(),
        {Finch, name: Patchbay.Assist.Target.finch()},
        # Room for two word searches at once.
        Patchbay.Forum.SearchSlots,
        {PatchbayWeb.ReadLimit, clean_period: :timer.minutes(1)},
        {PatchbayWeb.PaymentLimit, clean_period: :timer.minutes(1)},
        {PatchbayWeb.OfferReportLimit, clean_period: :timer.minutes(10)},
        {PatchbayWeb.CreditsLimit, clean_period: :timer.minutes(1)},
        PatchbayWeb.FixCheckLimit,
        # AshOban adds a queue and a sweep for every trigger in Patchbay's
        # domains and in Regent Credits, whose purchase checks run here.
        {Oban,
         AshOban.config(
           Application.fetch_env!(:patchbay, :ash_domains) ++ [RegentCredits],
           Application.fetch_env!(:patchbay, Oban)
         )},
        # After Oban: it measures how long each queue's oldest job has waited.
        PatchbayWeb.Telemetry.site_poller()
      ]
      |> Enum.reject(&is_nil/1)

    children =
      children ++
        site_loader() ++
        [
          # Start to serve requests, typically the last entry
          PatchbayWeb.Endpoint
        ] ++ metrics()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Patchbay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Metrics are served beside the site, never by a process that only runs a task.
  defp metrics do
    if serving?(), do: [PatchbayWeb.Metrics], else: []
  end

  # The bench is read only where pages are served, so a task or a test never
  # reads Techtree's views before it asks to.
  defp wallet_bench_board do
    if serving?(), do: Patchbay.WalletBench.Board
  end

  defp serving?, do: Phoenix.Endpoint.server?(:patchbay, PatchbayWeb.Endpoint)

  # The WebMCP catalog is synced and each program's site made once, at boot.
  defp site_loader do
    if Application.get_env(:patchbay, :load_sites_at_boot, true) do
      [
        {Task,
         fn ->
           Patchbay.Forum.Catalog.sync!()
           Patchbay.Forum.ProgramSites.make!()
         end}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PatchbayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
