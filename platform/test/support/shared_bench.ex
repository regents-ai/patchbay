defmodule PatchbayTest.SharedBench do
  @moduledoc """
  The Wallet Bench a test reads, as the minute's pass shares it
  (`Patchbay.WalletBench.Board`). Tests run with no endpoint serving, so no
  producer runs: a test that opens the board or How the bench works reads
  its own rows in with `share!/0` once they are in place. The shared reading
  is one table for the whole run, so such a test runs alone (`async: false`).
  """

  alias Patchbay.SharedReading
  alias Patchbay.WalletBench.Board

  @doc "Reads the bench now into the shared reading and forgets it when the test ends."
  def share! do
    ExUnit.Callbacks.on_exit(&forget/0)
    :ok = Board.refresh()
  end

  @doc "Forgets the shared bench, as a site that has not read it yet."
  def forget, do: Enum.each([:board, :rows, :method], &SharedReading.delete(Board.key(&1)))

  @doc """
  Runs `visit` and answers its result with each query it sent to Techtree's
  views, so a test can say a visit read none.
  """
  def views_read(visit) do
    test = self()
    handler = "views-read-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:patchbay, :repo, :query],
      fn _event, _measured, %{query: query}, _config ->
        if query =~ "techtree_app", do: send(test, {:view_read, query})
      end,
      nil
    )

    try do
      {visit.(), collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(read) do
    receive do
      {:view_read, query} -> collect([query | read])
    after
      0 -> Enum.reverse(read)
    end
  end
end
