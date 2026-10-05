defmodule Patchbay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attached before the endpoint so the first browser event of a boot is logged.
    :ok = Patchbay.Patchbay.TelemetryLogger.attach()

    children =
      [
        PatchbayWeb.Telemetry,
        Patchbay.Repo,
        {DNSCluster, query: Application.get_env(:patchbay, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Patchbay.PubSub},
        RegentAgents.Listener,
        RegentPayments.Supervisor,
        {Finch, name: Patchbay.Assist.Target.finch()},
        Patchbay.Escrow.Watch,
        Patchbay.Forum.NotificationFanout,
        {PatchbayWeb.ReadLimit, clean_period: :timer.minutes(1)},
        {PatchbayWeb.PaymentLimit, clean_period: :timer.minutes(1)},
        {PatchbayWeb.OfferReportLimit, clean_period: :timer.minutes(10)},
        PatchbayWeb.FixCheckLimit,
        {Oban,
         AshOban.config(
           Application.fetch_env!(:patchbay, :ash_domains),
           Application.fetch_env!(:patchbay, Oban)
         )}
      ] ++
        catalog_loader() ++
        patchbay_agent() ++
        site_check() ++
        [
          # Start to serve requests, typically the last entry
          PatchbayWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Patchbay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The WebMCP catalog is synced once, at boot.
  defp catalog_loader do
    if Application.get_env(:patchbay, :sync_webmcp_catalog, true) do
      [{Task, fn -> Patchbay.Forum.Catalog.sync!() end}]
    else
      []
    end
  end

  # The worker that repairs a reported tool runs beside the room it repairs.
  # Tests start their own when they want one, so the suite is never racing a
  # loop it did not ask for.
  defp patchbay_agent do
    if Application.get_env(:patchbay, :start_patchbay_agent, true) do
      [{Patchbay.Forum.PatchbayAgent, name: Patchbay.Forum.PatchbayAgent}]
    else
      []
    end
  end

  # Reads a newly asked-about site's page for tools. Tests run the check
  # directly and start no queue.
  defp site_check do
    if Application.get_env(:patchbay, :check_new_sites, true),
      do: [Patchbay.Forum.SiteCheck],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PatchbayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
