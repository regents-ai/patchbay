defmodule PatchbayWeb.WebMCP.RoomLive.Presenter do
  @moduledoc false

  use Phoenix.Component

  alias Patchbay.BoundedText
  alias Patchbay.Forum.RepairAttempt
  alias Patchbay.Patchbay.{BrowserSession, Invocation, Room, RoomEvent}
  alias PatchbayWeb.Forum.BoardHTML

  # Arguments, handler responses, and observed state all arrive from the browser,
  # so the rendered text is capped before it can reach the LiveView diff.
  @display_bytes 4_000

  # The board and the room are describing the same thing when a tool claims a
  # success the page never showed, so they say it with the same two words. The
  # board owns the pair; these are the room's states that mean it.
  @verdict_states %{
    failed: :verified_failure,
    verified_failure: :verified_failure,
    verified_success: :verified_success
  }

  def status_label(status) do
    case Map.fetch(@verdict_states, status) do
      {:ok, verdict} -> BoardHTML.verdict_label(verdict)
      :error -> title_case(status)
    end
  end

  defp title_case(status) do
    status
    |> status_key()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  What the page saw, with the machine code beside it. The words are the board's;
  the code is what a report or a log entry carries.
  """
  def page_verdict_note(%Invocation{failure_code: nil}),
    do: "Verified against what this page was showing"

  def page_verdict_note(%Invocation{failure_code: code}),
    do: "#{BoardHTML.verdict_label(:verified_failure)} · #{code}"

  def status_class(status) do
    case status_key(status) do
      value when value in ["verified", "repaired"] ->
        "is-good"

      value when value in ["failed", "error", "rejected", "canary_failed"] ->
        "is-bad"

      value when value in ["awaiting_approval", "repair_ready", "diagnosing", "publishing"] ->
        "is-warn"

      _ ->
        "is-neutral"
    end
  end

  def invocation_status_class(status) do
    case status_key(status) do
      "verified_success" -> "is-good"
      value when value in ["verified_failure", "errored", "cancelled"] -> "is-bad"
      _ -> "is-neutral"
    end
  end

  def proposal_status_class(status) do
    case status_key(status) do
      value when value in ["published", "approved"] -> "is-good"
      value when value in ["rejected", "failed", "canary_failed"] -> "is-bad"
      _ -> "is-warn"
    end
  end

  @doc """
  The tool's own claim is never proof, so a reported success is only ever
  neutral here. A reported error is the one thing worth colouring.
  """
  def handler_badge_class(%Invocation{handler_reported_success: true}), do: "is-neutral"
  def handler_badge_class(_invocation), do: "is-warn"

  @doc "Whether this page is showing a candidate the room itself proved."
  def proof_verified?(%Room{status: :verified}, _invocation), do: true

  def proof_verified?(_room, %Invocation{effective_status: :verified_success}), do: true

  def proof_verified?(_room, _invocation), do: false

  @doc """
  The Candidate editor is the page's evidence, so its panel carries the state
  it is in: waiting for a tool to write, holding an unproven candidate, or
  holding one this room verified.
  """
  def candidate_state_class(room, invocation) do
    cond do
      proof_verified?(room, invocation) -> "is-verified"
      is_binary(room.candidate_markdown) -> "is-filled"
      true -> "is-waiting"
    end
  end

  # The three moments of a repair, in the order they happen, and where each phase
  # of a worker's repair sits in that order. `:queued` is a repair that has not
  # started, and `:done` is one that is past every step.
  @repair_steps [
    {:reading, "Reading the failure"},
    {:testing, "Testing the replacement"},
    {:publishing, "Publishing the tool"}
  ]

  @phase_positions %{queued: 0, reading: 1, testing: 2, publishing: 3, done: 4}

  @doc """
  Whether the Patchbay Agent is somewhere in the repair it runs by itself, so
  the room can show its progress instead of an empty card.
  """
  def agent_at_work?(room, proposal, attempt) do
    attempt != nil or proposal != nil or
      room.status in [:diagnosing, :repair_ready, :awaiting_approval, :publishing]
  end

  @doc """
  The three moments of a repair and where it has got to.

  A repair the worker ran on a report wrote down every step it reached, so those
  steps are read straight off that record. A repair the owner asked for by hand
  writes nothing down, so its steps are read from what the room itself keeps: it
  is diagnosing, it has a proposal with a canary result, and it is publishing.
  Nothing here is guessed while the room is silent.
  """
  def agent_steps(room, proposal, attempt) do
    Enum.map(@repair_steps, fn {step, label} ->
      %{label: label, state: agent_step_state(step, room, proposal, attempt)}
    end)
  end

  @doc """
  Why a repair the worker ran stopped without replacing the tool, in the words
  the reply on the report uses. A repair still running, or one that finished,
  has nothing to say here.
  """
  def agent_stop_reason(%RepairAttempt{status: :errored}),
    do: "Patchbay could not finish this repair, so a person will need to look at it."

  def agent_stop_reason(%RepairAttempt{status: :not_reproduced, detail: detail})
      when is_binary(detail),
      do: "Patchbay did not replace the tool, because #{detail}."

  def agent_stop_reason(_attempt), do: nil

  defp agent_step_state(step, _room, _proposal, %RepairAttempt{} = attempt),
    do: attempt_step_state(attempt, step)

  defp agent_step_state(:reading, room, proposal, nil), do: diagnosis_state(room, proposal)
  defp agent_step_state(:testing, _room, proposal, nil), do: canary_state(proposal)
  defp agent_step_state(:publishing, room, _proposal, nil), do: publication_state(room)

  # The phase is the furthest step the repair reached and the status is how it
  # ended, so the two together say which step a stopped repair stopped on
  # without either of them having to guess.
  defp attempt_step_state(%RepairAttempt{phase: phase, status: status}, step) do
    cond do
      @phase_positions[phase] > @phase_positions[step] -> :done
      @phase_positions[phase] < @phase_positions[step] -> :waiting
      status in [:queued, :running] -> :working
      true -> :failed
    end
  end

  defp diagnosis_state(%Room{status: :diagnosing}, nil), do: :working
  defp diagnosis_state(_room, %{} = _proposal), do: :done

  defp diagnosis_state(%Room{status: status}, _proposal)
       when status in [:publishing, :repaired, :verified],
       do: :done

  defp diagnosis_state(_room, _proposal), do: :waiting

  defp canary_state(nil), do: :waiting

  defp canary_state(proposal) do
    cond do
      not is_map(proposal.canary_result) -> :waiting
      canary_passed?(proposal) -> :done
      true -> :failed
    end
  end

  defp publication_state(%Room{status: :publishing}), do: :working
  defp publication_state(%Room{status: status}) when status in [:repaired, :verified], do: :done
  defp publication_state(_room), do: :waiting

  @doc """
  The tool the room is offering right now. The first prompt calls it by name, so
  after a hot-swap the prompt names the replacement rather than the tool that is
  gone.
  """
  def active_tool_name(%{name: name}) when is_binary(name), do: name
  def active_tool_name(_), do: "the tool this room is offering"

  # Which prompt the room is waiting on, read from the room's own status rather
  # than from anything the page guesses. Four means all three are behind it.
  @steps %{
    ready: 1,
    failed: 2,
    diagnosing: 2,
    repair_ready: 2,
    awaiting_approval: 2,
    publishing: 2,
    repaired: 3,
    retrying: 3,
    verified: 4
  }

  @doc "Whether a numbered prompt is behind the room, in front of it, or the one to send now."
  def step_state(%Room{status: status}, step) do
    case Map.get(@steps, status) do
      nil -> "is-waiting"
      current when step < current -> "is-done"
      ^step -> "is-current"
      _ -> "is-waiting"
    end
  end

  @doc "Whether this numbered prompt is the one the room is waiting on."
  def current_step?(room, step), do: step_state(room, step) == "is-current"

  @doc """
  Why the Retry uplift button is off. The button only turns on once a
  replacement tool is published and nothing has retried it yet.
  """
  def retry_disabled_reason(%Room{status: :verified}),
    do: "The retry already ran and this page proved it. There is nothing left to retry."

  def retry_disabled_reason(_room),
    do: "No replacement tool is published yet. Approve the repair above and this turns on."

  @doc "Which part of the loop a timeline entry belongs to, for its dot colour."
  def event_class(kind) do
    case kind do
      kind
      when kind in [
             :room_reset,
             :webmcp_supported,
             :tool_registered,
             :tool_unregistered,
             :toolchange_observed,
             :registry_reconciled
           ] ->
        "is-registry"

      kind when kind in [:invocation_started, :handler_returned, :visible_state_observed] ->
        "is-invocation"

      :verification_passed ->
        "is-verification is-passed"

      :verification_failed ->
        "is-verification"

      kind
      when kind in [
             :repair_requested,
             :repair_proposed,
             :canary_passed,
             :canary_failed,
             :approval_granted,
             :approval_rejected,
             :agent_reading_failure,
             :agent_testing_replacement,
             :agent_repair_finished
           ] ->
        "is-repair"

      kind when kind in [:publication_requested, :agent_publishing_tool] ->
        "is-publication"

      :goal_verified ->
        "is-goal"

      _ ->
        "is-error"
    end
  end

  @doc "What an agent said happened when it called a tool, in the board's words."
  defdelegate report_verdict_label(verdict), to: BoardHTML, as: :verdict_label

  defdelegate report_verdict_class(verdict), to: BoardHTML, as: :verdict_class

  def observed_generation(nil), do: "—"
  def observed_generation(%BrowserSession{observed_generation: nil}), do: "—"
  def observed_generation(%BrowserSession{observed_generation: generation}), do: "G#{generation}"

  def session_label(nil), do: "not connected"
  def session_label(%BrowserSession{id: id}), do: short_id(id)

  def short_id(value) when is_binary(value) do
    if byte_size(value) > 12, do: String.slice(value, 0, 8) <> "…", else: value
  end

  def short_id(value), do: inspect(value)

  def short_digest(value) when is_binary(value) do
    if byte_size(value) > 16, do: String.slice(value, 0, 12) <> "…", else: value
  end

  def short_digest(_), do: "—"

  def fallback_used?(%Invocation{
        handler_result: %{"candidate_provenance" => %{"fallback_used" => true}}
      }),
      do: true

  def fallback_used?(_invocation), do: false

  def proposal_fallback?(proposal) do
    is_binary(proposal.model) and String.contains?(String.downcase(proposal.model), "fallback")
  end

  def diff_entries(diff) when is_map(diff),
    do: Enum.sort_by(diff, fn {field, _value} -> to_string(field) end)

  def diff_entries(_), do: []
  def diff_from(%{"from" => value}), do: value
  def diff_from(_diff), do: nil
  def diff_to(%{"to" => value}), do: value
  def diff_to(_diff), do: nil

  def format_value(value) when is_binary(value), do: value
  def format_value(nil), do: "—"
  def format_value(value) when is_atom(value), do: Atom.to_string(value)

  def format_value(value) do
    value |> printable_value() |> Jason.encode!(pretty: true)
  rescue
    _ -> inspect(value)
  end

  attr(:value, :any, required: true)

  def evidence_text(assigns) do
    {text, shortened?} = bounded_text(assigns.value)
    assigns = assign(assigns, text: text, shortened?: shortened?)

    ~H"""
    <pre>{@text}</pre>
    <p :if={@shortened?} class="patchbay-shortened-note">
      Shortened for display. The whole record is kept in the room evidence.
    </p>
    """
  end

  defp bounded_text(value) do
    value |> format_map() |> BoundedText.take(@display_bytes)
  end

  defp format_map(value) when is_map(value), do: format_value(value)
  defp format_map(value), do: inspect(value)

  def canary_passed?(%{canary_result: %{passed: true}}), do: true
  def canary_passed?(_proposal), do: false

  def canary_checks(%{checks: checks}) when is_map(checks) do
    checks
    |> Enum.map(fn {name, passed} -> {to_string(name), passed} end)
    |> Enum.sort_by(fn {name, _passed} -> name end)
  end

  def canary_checks(_result), do: []

  def upload_problems(%Phoenix.LiveView.UploadConfig{errors: errors}) do
    errors
    |> Enum.map(fn {_ref, reason} -> upload_problem(reason) end)
    |> Enum.uniq()
  end

  def upload_problems(_), do: []

  defp upload_problem(:too_large),
    do: "That file is larger than 64 KB. Upload a smaller Markdown Skill."

  defp upload_problem(:not_accepted),
    do: "Only Markdown Skill files ending in .md or .markdown can be uploaded."

  defp upload_problem(:too_many_files), do: "Upload one Markdown Skill file at a time."

  defp upload_problem(_reason),
    do: "That file could not be read. Upload a Markdown Skill saved as UTF-8 text."

  def event_label(kind) do
    %{
      room_reset: "Room reset",
      webmcp_supported: "WebMCP capability reported",
      tool_registered: "Tool registered",
      tool_unregistered: "Tool unregistered",
      toolchange_observed: "toolchange observed",
      registry_reconciled: "Browser registry reconciled",
      invocation_started: "Invocation started",
      handler_returned: "Handler returned",
      visible_state_observed: "Visible state observed",
      verification_passed: "Verification passed",
      verification_failed: "Visible postcondition failed",
      repair_requested: "Repair requested",
      repair_proposed: "Repair proposed",
      canary_passed: "Canary passed",
      canary_failed: "Canary failed",
      approval_granted: "Human approval granted",
      approval_rejected: "Repair rejected",
      publication_requested: "Publication requested",
      goal_verified: "Goal verified",
      agent_reading_failure: "Reading the failure",
      agent_testing_replacement: "Testing the replacement",
      agent_publishing_tool: "Publishing the tool",
      agent_repair_finished: "Repair finished",
      platform_error: "Platform error"
    }
    |> Map.get(kind, status_label(kind))
  end

  def timeline_detail(%RoomEvent{payload: payload}) when is_map(payload) do
    cond do
      is_binary(payload["failure_code"]) ->
        payload["failure_code"]

      is_binary(payload["failure"]) ->
        payload["failure"]

      is_integer(payload["generation"]) ->
        "Generation #{payload["generation"]}"

      is_boolean(payload["reported_success"]) ->
        if(payload["reported_success"], do: "reported success", else: "reported error")

      true ->
        "Recorded in room evidence"
    end
  end

  def timeline_detail(_), do: "Recorded in room evidence"

  attr(:id, :string, required: true)
  attr(:at, DateTime, required: true)

  @doc """
  When something happened.

  The server renders the clock time it happened at, which never goes stale
  between diffs, and the client turns it into "3 minutes ago" and keeps that
  fresh on its own. Sequence numbers stay server-side; only the wording moves.
  """
  def moment(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      phx-hook="PatchbayRelativeTime"
      phx-update="ignore"
    >{Calendar.strftime(@at, "%H:%M UTC")}</time>
    """
  end

  defp status_key(status) when is_atom(status), do: Atom.to_string(status)
  defp status_key(status) when is_binary(status), do: status
  defp status_key(status), do: inspect(status)

  defp printable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp printable_value(value) when is_list(value), do: Enum.map(value, &printable_value/1)

  defp printable_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), printable_value(item)} end)
  end

  defp printable_value(value), do: value
end
