defmodule Patchbay.SharedReadingTest do
  # Invariants of the figure every visitor sees alike, which all five sites
  # copy: a bad reading never replaces a good one, a failed first read is
  # visible, pages hear only about their own figure, and measuring survives the
  # table being away. Stops the table's owner, so it never runs beside another test.
  use ExUnit.Case, async: false

  alias Patchbay.SharedReading

  @key {:wallet_bench, "test-one"}
  @other {:wallet_bench, "test-two"}

  setup do
    on_exit(fn -> Enum.each([@key, @other], &SharedReading.delete/1) end)
  end

  test "a refused reading keeps the one held" do
    assert :ok = SharedReading.put(@key, 41)
    assert {:ok, %{at: at}} = SharedReading.fetch(@key)

    assert {:error, :too_large} = SharedReading.put(@key, String.duplicate("9", 48_000_001))
    assert {:error, :not_plain} = SharedReading.put(@key, 1..2)

    assert {:ok, %{reading: 41, at: ^at, degraded?: false}} = SharedReading.fetch(@key)
  end

  test "a first read that fails is marked, and pages hear it" do
    SharedReading.subscribe(@key)

    assert :ok = SharedReading.degraded(@key)

    assert_receive {:shared_reading, @key}
    assert {:ok, %{reading: nil, at: nil, degraded?: true}} = SharedReading.fetch(@key)
  end

  test "a change to one figure leaves pages watching another untouched" do
    SharedReading.subscribe(@key)

    assert :ok = SharedReading.put(@other, 7)
    assert :ok = SharedReading.degraded(@other)

    refute_receive {:shared_reading, _any}, 50
    assert :error = SharedReading.fetch(@key)
  end

  test "a measurement taken while the table is away is skipped, and measuring carries on" do
    test = self()
    event = [:patchbay, :shared_reading, :table]

    :telemetry.attach(
      "shared-reading-test",
      event,
      fn _, bytes, _, _ -> send(test, bytes) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("shared-reading-test")
      Supervisor.restart_child(Patchbay.Supervisor, SharedReading)
    end)

    :ok = Supervisor.terminate_child(Patchbay.Supervisor, SharedReading)

    assert :ok = SharedReading.measure()
    refute_received %{bytes: _}
    assert :error = SharedReading.fetch(@key)

    {:ok, _owner} = Supervisor.restart_child(Patchbay.Supervisor, SharedReading)

    SharedReading.measure()
    assert_received %{bytes: bytes} when bytes > 0
  end
end
