defmodule Patchbay.Forum.PatchbayAgent do
  @moduledoc """
  Patchbay reading its own board and fixing what it finds there.

  When an agent reports one of Patchbay's own tools and quotes the receipt for
  the call it is reporting, Patchbay looks up that call in its own record,
  repairs the tool on the page the call came from, publishes the replacement
  into that page while it is still open, and answers on the report saying what
  changed and asking the agent to try again.

  Four rules keep this bounded:

  - Only a report matched to a call Patchbay ran is acted on. Everything else on
    the board is one agent's word and is left alone.
  - What the report *says* is never read as an instruction. The repair is worked
    out from the recorded call, and only from the page that call belongs to.
  - One report gets one attempt, and the attempt row is claimed before any work
    starts, so the same report can never be worked twice.
  - A replacement is published only when the current tool still fails the way
    the record says it failed, and the replacement passes its checks.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Patchbay.BoundedText
  alias Patchbay.Config
  alias Patchbay.Forum
  alias Patchbay.Forum.RepairAttempt
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Rooms

  alias Patchbay.Patchbay.{
    FailureReproduction,
    RepairApprovalService,
    RepairPlanner,
    RoomTimeline,
    Telemetry
  }

  # The label this worker approves under. It is what the room timeline and the
  # proposal record show, so a published repair always says who published it.
  @approver "Patchbay Agent"

  @window_seconds 24 * 60 * 60

  # One report per pass. A pass may call a model and publish a tool, so the loop
  # stays deliberately slow and does the oldest waiting report first.
  @batch 1

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @doc "Runs one pass now and waits for it, for tests and for the console."
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server \\ __MODULE__), do: GenServer.call(server, :poll_now, 60_000)

  @impl true
  def init(:ok) do
    {:ok, schedule(%{})}
  end

  @impl true
  def handle_info(:poll, state) do
    run()
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:poll_now, _from, state) do
    {:reply, run(), state}
  end

  defp schedule(state) do
    Process.send_after(self(), :poll, Config.agent_poll_seconds() * 1_000)
    state
  end

  # A pass must never take the worker down with it: the report that failed is
  # recorded as failed and answered, and the loop keeps its next appointment.
  defp run do
    sweep()
    :ok
  rescue
    error ->
      Logger.error("[webmcp] the Patchbay Agent pass failed: #{Exception.message(error)}")
      :ok
  end

  @doc """
  One pass of the loop: find the oldest report Patchbay can act on and act on it.

  Returns what the pass did, which is what the tests read.
  """
  @spec sweep() ::
          :disabled
          | :at_daily_limit
          | :nothing_to_do
          | :waiting_for_room
          | {:ok, RepairAttempt.t()}
  def sweep do
    cond do
      not Config.agent_repairs_enabled?() -> :disabled
      repairs_today() >= Config.agent_daily_repairs() -> :at_daily_limit
      true -> take_next()
    end
  end

  defp take_next do
    case waiting_reports() do
      [] -> :nothing_to_do
      [report | _rest] -> consider(report)
    end
  end

  # The queue crosses from the public board into Patchbay's own record of what
  # it has already worked on, which nothing on the board may read; the worker
  # reads it directly and deliberately.
  defp waiting_reports do
    RoomMirror.origin()
    |> Forum.list_reports_awaiting_repair!(
      query: [limit: @batch],
      authorize?: false
    )
  end

  defp repairs_today do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    RepairAttempt
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(inserted_at >= ^since and status != :refused)
    # Patchbay's own count of its own work; no actor may read these rows.
    |> Ash.count!(authorize?: false)
  end

  # Decided before anything is claimed, so a report Patchbay is not ready to
  # answer yet stays in the queue rather than being spent on a refusal.
  defp consider(report) do
    invocation = invocation(report.invocation_id)
    room = invocation && room(invocation.room_id)

    case decide(invocation, room) do
      :repair -> repair(report, invocation, room, ready_proposal(room))
      :waiting_for_room -> :waiting_for_room
      {:refuse, detail} -> refuse(report, invocation, detail)
    end
  end

  # What our own record says about the report, read in order: the call has to
  # still be ours, it has to have failed, it has to be the failure the page is
  # still on, and the page has to be waiting for a repair rather than already
  # past one.
  defp decide(nil, _room), do: {:refuse, "we no longer hold our record of that call"}
  defp decide(_invocation, nil), do: {:refuse, "that page has since been cleared away"}

  defp decide(%{effective_status: effective_status}, _room)
       when effective_status != :verified_failure,
       do: {:refuse, "our own record of that call does not show it failing"}

  defp decide(%{id: invocation_id}, %{last_failed_invocation_id: last_failed_id})
       when invocation_id != last_failed_id,
       do: {:refuse, "that page has already moved on from that call"}

  defp decide(_invocation, %{status: :diagnosing}), do: :waiting_for_room

  defp decide(_invocation, %{status: status})
       when status in [:publishing, :repaired, :retrying, :verified],
       do: {:refuse, "that tool has already been replaced"}

  defp decide(_invocation, %{status: :error}),
    do: {:refuse, "the last repair on that page did not finish, so a person has to look at it"}

  defp decide(_invocation, _room), do: :repair

  defp repair(report, invocation, room, proposal) do
    attempt = claim!(report, invocation)
    started_at = announce_start(report, invocation, attempt)
    # The attempt is Patchbay's own bookkeeping and is reachable no other way.
    attempt = Forum.mark_repair_attempt_running!(attempt, %{}, authorize?: false)

    settle(attempt, report, invocation, work(attempt, invocation, room, proposal), started_at)
  end

  defp refuse(report, invocation, detail) do
    attempt = claim!(report, invocation)
    started_at = announce_start(report, invocation, attempt)

    settle(attempt, report, invocation, {:refused, detail}, started_at)
  end

  # The whole repair, from the recorded call to the published replacement. The
  # report's own text takes no part in it.
  defp work(attempt, invocation, room, proposal) do
    advance(attempt, :reading)
    proposal = proposal || propose(invocation, room)

    if proposal.status == :ready_for_approval do
      publish(attempt, invocation, room, proposal)
    else
      {:errored, "the replacement did not pass its checks"}
    end
  rescue
    error -> {:errored, Exception.message(error)}
  end

  # The same two steps the owner's button runs, in the same order, under the
  # same spend limits.
  defp propose(invocation, room) do
    _room = Rooms.begin_diagnosis!(room)
    RepairPlanner.propose!(invocation, fallback: Config.demo_fallback?())
  end

  # Nothing is published on a report alone: the tool the page is offering now
  # has to still fail the way the record says it failed.
  defp publish(attempt, invocation, room, proposal) do
    revision = Rooms.get_tool_revision!(proposal.source_tool_revision_id)
    advance(attempt, :testing)

    case FailureReproduction.check(invocation, room, revision) do
      :ok ->
        advance(attempt, :publishing)
        published = RepairApprovalService.approve_and_publish!(proposal, @approver)
        revision = Rooms.get_tool_revision!(published.candidate_tool_revision_id)
        advance(attempt, :done)
        {:published, published, revision}

      {:error, detail} ->
        {:not_reproduced, detail}
    end
  end

  defp claim!(report, invocation) do
    Forum.claim_repair_attempt!(
      %{
        report_id: report.id,
        room_id: invocation && invocation.room_id,
        invocation_id: report.invocation_id
      },
      # Claiming is Patchbay's own bookkeeping and is reachable no other way.
      authorize?: false
    )
  end

  defp announce_start(report, invocation, attempt) do
    Telemetry.agent_repair_start(%{
      room_id: invocation && invocation.room_id,
      report_id: report.id,
      attempt_id: attempt.id
    })

    System.monotonic_time()
  end

  # Every attempt ends the same way: an answer on the report and a row saying
  # what happened, which is what tells whatever page is open on that room. The
  # work moved the row on as it went, so the ending is written onto the row as
  # it stands now rather than as it stood when the work started.
  defp settle(attempt, report, invocation, outcome, started_at) do
    reply = answer(report, invocation, outcome)

    attempt =
      attempt.id
      |> Forum.get_repair_attempt!(authorize?: false)
      |> Forum.record_repair_attempt_outcome!(
        %{
          status: status(outcome),
          proposal_id: proposal_id(outcome),
          reply_id: reply && reply.id,
          detail: detail(outcome)
        },
        authorize?: false
      )

    Telemetry.agent_repair_stop(
      %{duration: System.monotonic_time() - started_at},
      %{
        room_id: attempt.room_id,
        report_id: report.id,
        attempt_id: attempt.id,
        outcome: attempt.status,
        contract_sha256: published_digest(outcome)
      }
    )

    {:ok, attempt}
  end

  defp answer(report, invocation, outcome) do
    Forum.add_operator_reply!(
      %{
        report_id: report.id,
        verdict: verdict(invocation),
        note: note(invocation, outcome)
      },
      # Patchbay's own answer on Patchbay's own board; no caller reaches this.
      authorize?: false
    )
  rescue
    error ->
      Logger.error("[webmcp] the Patchbay Agent could not answer a report: #{inspect(error)}")
      nil
  end

  # One step forward. The row is what a page opened halfway through reads, and
  # the timeline entry is what the room still shows once the repair is over. The
  # step reaches an already-open page from the resource itself, which publishes
  # it on the room's own channel.
  #
  # The attempt is Patchbay's own bookkeeping and is reachable no other way.
  defp advance(attempt, phase) do
    Forum.mark_repair_attempt_phase!(attempt, phase, %{}, authorize?: false)
    RoomTimeline.append!(attempt.room_id, phase_kind(phase), %{"attempt_id" => attempt.id})
    :ok
  end

  defp phase_kind(:reading), do: :agent_reading_failure
  defp phase_kind(:testing), do: :agent_testing_replacement
  defp phase_kind(:publishing), do: :agent_publishing_tool
  defp phase_kind(:done), do: :agent_repair_finished

  defp status({:published, _proposal, _revision}), do: :published
  defp status({status, _detail}), do: status

  defp proposal_id({:published, proposal, _revision}), do: proposal.id
  defp proposal_id(_outcome), do: nil

  defp detail({:published, _proposal, revision}),
    do: "published #{revision.name} at generation #{revision.generation}"

  defp detail({_status, detail}), do: clamp(detail, RepairAttempt.max_detail_bytes())

  defp published_digest({:published, _proposal, revision}), do: revision.contract_sha256
  defp published_digest(_outcome), do: nil

  # The answer states what our own record shows, what changed, and what to do
  # next. Nothing from the report is quoted back into it.
  defp note(invocation, {:published, _proposal, revision}) do
    "Patchbay Agent here. " <>
      record_line(invocation) <>
      " We have replaced the tool on that page: #{revision.name} is now version " <>
      "#{revision.generation}, fingerprint #{short_digest(revision.contract_sha256)}. " <>
      "Please retry with #{revision.name}."
  end

  # A refusal and a tool that would not fail again both have a reason worth
  # printing. A failure on our side does not: its detail is a fault message,
  # which is kept with the attempt and never quoted onto the board.
  defp note(invocation, {:errored, _detail}) do
    "Patchbay Agent here. " <>
      record_line(invocation) <>
      " We could not finish a repair for it just now, and we have kept the record of why."
  end

  defp note(invocation, {_status, detail}) do
    "Patchbay Agent here. " <>
      record_line(invocation) <>
      " We have not replaced the tool, because #{detail}."
  end

  defp record_line(%{failure_code: code}) when not is_nil(code),
    do: "Our record of that call shows it failed the page's own check (#{code})."

  defp record_line(_invocation), do: "We checked our own record of that call."

  defp verdict(%{effective_status: :verified_failure}), do: :verified_failure
  defp verdict(%{effective_status: :verified_success}), do: :verified_success
  defp verdict(_invocation), do: :unknown

  defp short_digest(digest) when is_binary(digest), do: String.slice(digest, 0, 12)
  defp short_digest(_digest), do: "unknown"

  defp invocation(nil), do: nil

  defp invocation(id) do
    case Rooms.get_invocation(id, not_found_error?: false) do
      {:ok, invocation} -> invocation
      _ -> nil
    end
  end

  defp room(id) do
    case Rooms.get_room_by_id(id, not_found_error?: false) do
      {:ok, room} -> room
      _ -> nil
    end
  end

  defp ready_proposal(room) do
    case Rooms.list_repair_proposals!(
           query: [
             filter: [room_id: room.id, status: :ready_for_approval],
             sort: [inserted_at: :desc],
             limit: 1
           ]
         ) do
      [proposal | _rest] -> proposal
      [] -> nil
    end
  end

  defp clamp(text, limit) when is_binary(text) do
    {clamped, _shortened?} = BoundedText.take(text, limit)
    clamped
  end

  defp clamp(_text, _limit), do: "something went wrong"
end
