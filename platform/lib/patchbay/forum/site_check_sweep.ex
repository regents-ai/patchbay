defmodule Patchbay.Forum.SiteCheckSweep do
  @moduledoc """
  Patchbay's own reading of every listed site, without anyone asking. Every
  five minutes (config/config.exs) it asks for checks of the next few listed
  domains: first those no check has been asked for yet, in listing order,
  then those whose last check is due again (`Patchbay.Forum.SiteCheck.due?/1`:
  a day old, and none on its way), the longest unchecked first.

  Each ask is the same `:request` a visitor's makes, which checks again at
  the write that the site is due and queues the check's job in the same
  write, one job per site. The `site_checks` queue still runs two checks at
  once, so this only adds a few to the line; the ask itself runs on
  `default`, so it never takes one of those two places. A check that cannot
  finish keeps what the last one found, and its site comes round again in a
  later run.

  `enabled?: false` turns the asking off; checks already asked for still run.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteDirectory

  @batch 5

  @doc "How many domains each run asks for."
  @spec batch() :: pos_integer()
  def batch, do: @batch

  @impl Oban.Worker
  def perform(_job) do
    if Application.fetch_env!(:patchbay, __MODULE__)[:enabled?] do
      new = never_asked()
      Enum.each(new ++ due_again(@batch - length(new)), &Forum.request_site_check!/1)
    end

    :ok
  end

  defp never_asked do
    asked = MapSet.new(Forum.list_asked_site_check_domains!(), & &1.domain)

    SiteDirectory.domains()
    |> Stream.reject(&MapSet.member?(asked, &1))
    |> Enum.take(@batch)
  end

  defp due_again(0), do: []

  defp due_again(count) do
    SiteDirectory.domains()
    |> Forum.list_site_checks_due_again!(query: [limit: count])
    |> Enum.map(& &1.domain)
  end
end
