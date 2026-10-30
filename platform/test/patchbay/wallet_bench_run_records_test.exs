defmodule Patchbay.WalletBenchRunRecordsTest do
  @moduledoc """
  Each run's public record from Techtree, kept and shared by every visitor
  (`Patchbay.WalletBench.RunRecords`): visitors who arrive together make one
  read, and a failed read is kept only a minute so the run is asked again soon.
  """

  # Each test reads a run of its own, so the shared cache keeps them apart.
  use ExUnit.Case, async: true

  alias Patchbay.WalletBench.RunRecords

  setup do
    run = %{attempt_id: Ecto.UUID.generate(), harness_id: "H1", wallet_id: "W1"}
    reads = :counters.new(1, [])
    %{run: run, reads: reads}
  end

  defp record(run) do
    %{
      "id" => run.attempt_id,
      "harness_id" => run.harness_id,
      "wallet_id" => run.wallet_id,
      "timeline" => [],
      "funding" => [],
      "tests" => []
    }
  end

  test "ten visitors arriving while the record is read make one read", %{run: run, reads: reads} do
    Req.Test.stub(Patchbay.WalletBench.PublicRun, fn conn ->
      :counters.add(reads, 1, 1)
      Process.sleep(200)
      Req.Test.json(conn, record(run))
    end)

    results =
      1..10
      |> Enum.map(fn _visitor -> Task.async(fn -> RunRecords.read(run) end) end)
      |> Task.await_many(5_000)

    assert results == List.duplicate({:ok, record(run)}, 10)
    assert :counters.get(reads, 1) == 1
    assert RunRecords.ttl!({run.attempt_id, run.harness_id, run.wallet_id}) > :timer.minutes(4)
  end

  test "a failed read is shared too, and kept only a minute", %{run: run, reads: reads} do
    Req.Test.stub(Patchbay.WalletBench.PublicRun, fn conn ->
      :counters.add(reads, 1, 1)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    for _visitor <- 1..10, do: assert(RunRecords.read(run) == {:error, :unavailable})

    assert :counters.get(reads, 1) == 1
    assert RunRecords.ttl!({run.attempt_id, run.harness_id, run.wallet_id}) <= :timer.minutes(1)
  end
end
