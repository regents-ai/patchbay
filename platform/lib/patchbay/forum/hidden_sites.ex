defmodule Patchbay.Forum.HiddenSites do
  @moduledoc """
  The listed sites the site directory leaves out (`Patchbay.Forum.SiteDirectory`),
  read once and shared by every listing on this machine, so a visit to
  `/sites`, its JSON and Markdown, the `read_site_directory` tool or the
  sitemap reads nothing from the database for them. It runs on each machine
  that serves pages and keeps its reading in `Patchbay.SharedReading` under
  `key/0`: the hidden hosts and the domains all of whose hosts are hidden.

  This is the second shape the `elixir-stack` skill lets keep a shared
  reading, a reread on notice. Every check `Patchbay.Forum.SiteCheck` records
  or gives up on is told on `"site_checks"`; this process rereads at most once
  a second however many arrive, holding nothing but whether a reread is due.
  A lost notice is mended by the minute's heal: the site's Oban schedule runs
  `Patchbay.SharedReading.Heal` for `:hidden_sites` each minute.

  The first read happens as it starts, before the endpoint serves a page. A
  read that fails keeps the last reading, marked degraded, and logs one
  warning line. While nothing has been read, nothing is hidden: every listing
  shows every site, as before a check had found a site without tools.
  """

  use GenServer

  require Logger

  alias Patchbay.Forum.SiteDirectory
  alias Patchbay.SharedReading

  @kind :hidden_sites
  @key {@kind, "directory"}
  @topic "site_checks"
  @debounce :timer.seconds(1)

  @type reading :: %{hosts: MapSet.t(String.t()), domains: MapSet.t(String.t())}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The shared reading's key."
  @spec key() :: SharedReading.key()
  def key, do: @key

  @doc "The topic every recorded or abandoned check is told on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The hidden hosts and domains as last read; none while nothing has been read."
  @spec reading() :: reading()
  def reading do
    case SharedReading.fetch(@key) do
      {:ok, %{reading: %{hosts: hosts, domains: domains}}} ->
        %{hosts: MapSet.new(hosts), domains: MapSet.new(domains)}

      _unread ->
        %{hosts: MapSet.new(), domains: MapSet.new()}
    end
  end

  @doc """
  Reads the hidden sites again and shares them. The process calls it as it
  starts, on each notice and on each minute's heal; a test calls it directly.
  """
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    with {:ok, hosts} <- SiteDirectory.read_hidden_hosts(),
         :ok <-
           SharedReading.put(@key, %{
             hosts: Enum.sort(hosts),
             domains: hosts |> SiteDirectory.hidden_domains() |> Enum.sort()
           }) do
      :ok
    else
      {:error, reason} = failed ->
        Logger.warning(
          "Hidden sites: the read of site checks failed, so listings keep the last " <>
            "reading: #{inspect(reason, limit: 5)}"
        )

        SharedReading.degraded(@key)
        failed
    end
  end

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(@kind)
    Phoenix.PubSub.subscribe(Patchbay.PubSub, @topic)
    refresh()
    {:ok, :idle, :hibernate}
  end

  @impl true
  def handle_info({:shared_reading_heal, @kind}, state) do
    refresh()
    {:noreply, state, :hibernate}
  end

  def handle_info(%Ash.Notifier.Notification{}, :idle) do
    Process.send_after(self(), :reread, @debounce)
    {:noreply, :due}
  end

  def handle_info(%Ash.Notifier.Notification{}, :due), do: {:noreply, :due}

  def handle_info(:reread, :due) do
    refresh()
    {:noreply, :idle, :hibernate}
  end
end
