defmodule Patchbay.Forum.ReadByJev do
  @moduledoc """
  The `:read_by_jev` action of `Patchbay.Forum.Report`: has Jev read one
  published paid priority report and writes down what it made of it. Its job
  (the `:read_by_jev` trigger) runs while the report has no reading. A call
  that fails is tried again later, five tries in all, and after the last the
  report is given up on (`:give_up_on_jev`), so a report Jev cannot answer is
  not asked about forever.

  A Patchbay without Jev's key asks nothing and leaves the report waiting.
  Nothing waits on this: a thread without a reading simply has no Jev line.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Forum
  alias Patchbay.Forum.Jev

  @impl true
  def update(changeset, _opts, _context) do
    report = changeset.data
    if Jev.configured?(), do: read(report), else: {:ok, report}
  end

  # Patchbay's own job: it answers to nobody's request.
  defp read(report) do
    with {:ok, report} <- Ash.load(report, [:site, :tool], authorize?: false),
         {:ok, answers} <- Jev.read(report),
         {:ok, _reading} <-
           Forum.record_jev_reading(Map.put(answers, :report_id, report.id), authorize?: false) do
      {:ok, report}
    end
  end
end
