defmodule PatchbayWeb.WebMCP.RoomLive.Presenter do
  @moduledoc false

  use Phoenix.Component

  alias Patchbay.Patchbay.{BrowserSession, Invocation, Room, RoomEvent}

  # Arguments, handler responses, and observed state all arrive from the browser,
  # so the rendered text is capped before it can reach the LiveView diff.
  @display_bytes 4_000

  def status_label(status) do
    status
    |> status_key()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

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

  @doc """
  Whether the Patchbay Agent is somewhere in the repair it runs by itself, so
  the room can show its progress instead of an empty card.
  """
  def agent_at_work?(room, proposal) do
    proposal != nil or
      room.status in [:diagnosing, :repair_ready, :awaiting_approval, :publishing]
  end

  @doc """
  The three moments of a repair, each one read from state the room actually
  keeps: it is diagnosing, it has a proposal with a canary result, and it is
  publishing. Nothing here is guessed while the room is silent.
  """
  def agent_steps(room, proposal) do
    [
      %{label: "Reading the failure", state: diagnosis_state(room, proposal)},
      %{label: "Testing the replacement", state: canary_state(proposal)},
      %{label: "Publishing the tool", state: publication_state(room)}
    ]
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
             :approval_rejected
           ] ->
        "is-repair"

      :publication_requested ->
        "is-publication"

      :goal_verified ->
        "is-goal"

      _ ->
        "is-error"
    end
  end

  @verdicts %{
    verified_success: "Worked",
    verified_failure: "Did not work",
    errored: "Errored",
    unknown: "Unclear"
  }

  @doc "What an agent said happened when it called a tool, in the board's words."
  def report_verdict_label(verdict), do: Map.get(@verdicts, verdict, "Unclear")

  def report_verdict_class(:verified_success), do: "is-good"

  def report_verdict_class(verdict) when verdict in [:verified_failure, :errored],
    do: "is-bad"

  def report_verdict_class(_verdict), do: "is-neutral"

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

  def fallback_used?(%Invocation{handler_result: result}) when is_map(result) do
    provenance = map_value(result, :candidate_provenance, %{})
    map_value(provenance, :fallback_used, false) == true
  end

  def fallback_used?(_), do: false

  def proposal_fallback?(proposal) do
    is_binary(proposal.model) and String.contains?(String.downcase(proposal.model), "fallback")
  end

  def diff_entries(diff) when is_map(diff),
    do: Enum.sort_by(diff, fn {field, _value} -> to_string(field) end)

  def diff_entries(_), do: []
  def diff_from(diff) when is_map(diff), do: map_value(diff, :from, nil)
  def diff_from(_), do: nil
  def diff_to(diff) when is_map(diff), do: map_value(diff, :to, nil)
  def diff_to(_), do: nil

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
    text = format_map(value)

    if byte_size(text) > @display_bytes do
      {truncate_bytes(text, @display_bytes), true}
    else
      {text, false}
    end
  end

  defp truncate_bytes(text, limit) do
    <<chunk::binary-size(limit), _rest::binary>> = text
    trim_to_text(chunk)
  end

  # A byte cut can land inside a multi-byte character, so drop trailing bytes
  # until what is left is printable text again.
  defp trim_to_text(chunk) do
    if String.valid?(chunk),
      do: chunk,
      else: trim_to_text(binary_part(chunk, 0, byte_size(chunk) - 1))
  end

  defp format_map(value) when is_map(value), do: format_value(value)
  defp format_map(value), do: inspect(value)

  def canary_passed?(proposal), do: map_value(proposal.canary_result, :passed, false) == true

  def canary_checks(result) when is_map(result) do
    result |> map_value(:checks, %{}) |> Enum.sort_by(fn {name, _passed} -> to_string(name) end)
  end

  def canary_checks(_), do: []

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
      platform_error: "Platform error"
    }
    |> Map.get(kind, status_label(kind))
  end

  def timeline_detail(%RoomEvent{payload: payload}) when is_map(payload) do
    cond do
      is_binary(map_value(payload, :failure_code, nil)) ->
        map_value(payload, :failure_code, "")

      is_binary(map_value(payload, :failure, nil)) ->
        map_value(payload, :failure, "")

      is_integer(map_value(payload, :generation, nil)) ->
        "Generation #{map_value(payload, :generation, 0)}"

      is_boolean(map_value(payload, :reported_success, nil)) ->
        if(map_value(payload, :reported_success, false),
          do: "reported success",
          else: "reported error"
        )

      true ->
        "Recorded in room evidence"
    end
  end

  def timeline_detail(_), do: "Recorded in room evidence"

  def relative_time(%DateTime{} = inserted_at) do
    seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> Calendar.strftime(inserted_at, "%H:%M:%S")
    end
  end

  def relative_time(_), do: ""

  def map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  def map_value(_map, _key, default), do: default

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
