defmodule Patchbay.Offers.Watch do
  @moduledoc """
  Every five minutes, while a market is set (the line is added to the Oban
  cron only then, in `config/runtime.exs`), makes sure the market has its
  reading job (`Patchbay.Offers.ReadMarket`). After a person's purchase or
  claim lands, `refresh/0` brings that job forward, so the page shows it soon.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Patchbay.Offers
  alias Patchbay.Offers.ReadMarket

  # The least time between two early reads, so a crowd pressing costs one.
  @gap_seconds 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Offers.enabled?(), do: Oban.insert!(job())
    :ok
  end

  @doc """
  Brings the market's next read to ten seconds from now, unless it was already
  due sooner, so presses that keep coming never put the read off.
  """
  @spec refresh() :: :ok
  def refresh do
    if Offers.enabled?(), do: bring_forward(Oban.insert!(job()))
    :ok
  end

  defp bring_forward(%Oban.Job{state: state, scheduled_at: at} = job)
       when state in ["scheduled", "retryable"] do
    soon = DateTime.add(DateTime.utc_now(), @gap_seconds)
    if DateTime.after?(at, soon), do: {:ok, _job} = Oban.update_job(job, %{scheduled_at: soon})
  end

  defp bring_forward(%Oban.Job{}), do: nil

  defp job,
    do: ReadMarket.new(%{chain_id: Offers.chain().chain_id, market: Offers.market()})
end
