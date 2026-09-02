defmodule Patchbay.Patchbay.FailureReproduction do
  @moduledoc """
  Whether the tool a page is offering right now still fails the way the record
  of a reported call says it failed.

  A report is an account of something that already happened, and a page can
  change between the call and the moment anyone acts on the report. So before a
  replacement is published on a report's account, the tool that is actually on
  the page is put through the same fixed check the replacement is put through,
  and it has to fail it in exactly the way the recorded call did. If it passes,
  or fails some other way, nothing is published.
  """

  alias Patchbay.Patchbay.{CanaryRunner, Invocation, Room, ToolRevision}

  @spec check(Invocation.t(), Room.t(), ToolRevision.t()) :: :ok | {:error, String.t()}
  def check(%Invocation{} = invocation, %Room{} = room, %ToolRevision{} = revision) do
    result = CanaryRunner.run(room.source_markdown, invocation.generated_candidate, revision)

    if result.passed == false and result.failure_code == invocation.failure_code do
      :ok
    else
      {:error, "the tool on that page did not fail that way when we checked it again"}
    end
  end
end
