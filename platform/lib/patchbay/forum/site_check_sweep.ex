defmodule Patchbay.Forum.SiteCheckSweep do
  @moduledoc """
  Asks, every ten minutes, for checks of the next few listed domains that no
  check has been asked for yet, in listing order, so every site in the
  directory is read without a visitor opening it. Each ask is the same
  `:request` a visitor's makes and queues the check's job in the same write;
  the `site_checks` queue still runs two checks at once, so this only adds to
  the line. The sweep itself runs on `default`, leaving both of those places
  to the checks. A domain already asked for, by anyone, is never asked again here:
  after its first check, visitors' daily rule decides when it is read.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteDirectory

  @batch 5

  @doc "How many domains each run asks for."
  @spec batch() :: pos_integer()
  def batch, do: @batch

  @impl Oban.Worker
  def perform(_job) do
    asked = MapSet.new(Forum.list_asked_site_check_domains!(), & &1.domain)

    SiteDirectory.domains()
    |> Stream.reject(&MapSet.member?(asked, &1))
    |> Enum.take(@batch)
    |> Enum.each(&Forum.request_site_check!/1)

    :ok
  end
end
