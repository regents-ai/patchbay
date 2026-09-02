defmodule PatchbayWeb.WebMCP.RoomLive.Show do
  @moduledoc """
  The single-room Skill Uplift Studio.

  This LiveView is deliberately small: Phoenix owns the durable room state and
  the WebMCP island reports browser observations back through the event names
  below. A browser tool can ask for a diagnosis, which runs the same path as the
  owner's button. No browser tool can approve or publish a repair.

  A repair can also be published from outside this process, by the worker that
  answers a receipt-verified report about this room's tool. That arrives on the
  room's channel and is handled exactly as the owner's own click is, so an open
  page hot-swaps the tool without being reloaded.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.Nameplate
  import PatchbayWeb.WebMCP.RoomLive.Presenter

  alias Patchbay.Config
  alias Patchbay.Forum
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Domain
  alias PatchbayWeb.Forum.Board

  alias Patchbay.Patchbay.{
    BrowserSession,
    CandidateGenerator,
    DemoReset,
    Digest,
    Invocation,
    InvocationRunner,
    RepairApprovalService,
    RepairPlanner,
    RepairProposal,
    Room,
    RoomTimeline
  }

  require Ash.Query

  @permanent_tool_names [
    "get_patchbay_room_state",
    "verify_skill_uplift_goal",
    "request_patchbay_repair"
  ]
  @max_observed_tool_names length(@permanent_tool_names) + 1
  @sha256_regex ~r/\A[0-9a-f]{64}\z/
  @no_proposal "No repair proposal is waiting for a human decision"

  # Everything the page says about a room, read with the room itself: the call
  # it is showing and the tool that call ran, the tool it offers now, and the
  # repair waiting for a decision with the two tools it stands between.
  @page_loads [
    :desired_tool_revision,
    latest_invocation: [:tool_revision],
    active_repair_proposal: [:source_tool_revision, :candidate_tool_revision]
  ]

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
    room = load_room!(slug)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Patchbay.PubSub, Room.topic(room.id))
    end

    {:ok,
     socket
     |> assign(assigns_for(room, nil))
     |> assign(
       page_title: room.title,
       # The identity this browser posts to the board under. A receipt this room
       # issues is only honoured in a report filed from the same browser.
       forum_session_id: Map.get(session, "forum_session_id"),
       error_message: nil,
       upload_error: nil,
       confirming_reset: false,
       pending_operation: nil,
       repair_token: nil,
       invocation_epoch: room.invocation_epoch,
       invocation_keys: MapSet.new()
     )
     |> allow_upload(:skill,
       accept: ~w(.md .markdown),
       max_entries: 1,
       max_file_size: Digest.max_artifact_bytes()
     )}
  end

  @impl true
  def handle_event("webmcp_bootstrap", params, socket) do
    room = socket.assigns.room

    with :ok <- valid_room_event?(params, room),
         {:ok, client_instance_id} <- client_instance_id(params),
         {:ok, browser_session} <-
           register_browser_session(
             room,
             params,
             client_instance_id,
             socket.assigns.forum_session_id
           ) do
      append_event(
        room,
        :webmcp_supported,
        %{
          "supported" => browser_session.webmcp_supported,
          "client_instance_id" => client_instance_id
        },
        browser_session
      )

      socket =
        socket
        |> refresh_observation(browser_session)
        |> assign(invocation_epoch: room.invocation_epoch)
        |> push_desired_toolset()
        |> assign(error_message: nil)

      {:reply,
       %{
         "browser_session_id" => browser_session.id,
         "client_instance_id" => browser_session.client_instance_id,
         "invocation_epoch" => socket.assigns.invocation_epoch,
         "desired_generation" => room.desired_tool_generation,
         # The site this page files reports under, so a tool result can say
         # where the call it is reporting happened.
         "origin" => RoomMirror.origin(),
         "revisions" => [revision_payload(socket.assigns.active_tool)]
       }, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_registry_reconciled", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         {:ok, attrs} <- registry_attributes(params, socket.assigns, :reconciled) do
      browser_session = Domain.observe_browser_session!(browser_session, attrs)

      append_event(
        socket.assigns.room,
        :registry_reconciled,
        %{
          "generation" => browser_session.observed_generation,
          "tool_names" => browser_session.observed_tool_names,
          "contracts" => browser_session.observed_contracts
        },
        browser_session
      )

      socket =
        socket
        |> refresh_observation(browser_session)
        |> assign(error_message: nil)

      {:reply, %{"ok" => true}, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_toolchange_observed", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         {:ok, attrs} <- registry_attributes(params, socket.assigns, :toolchange) do
      attrs = Map.put(attrs, :toolchange_count, browser_session.toolchange_count + 1)
      browser_session = Domain.observe_browser_session!(browser_session, attrs)

      append_event(
        socket.assigns.room,
        :toolchange_observed,
        %{
          "generation" => browser_session.observed_generation,
          "tool_names" => browser_session.observed_tool_names,
          "contracts" => browser_session.observed_contracts
        },
        browser_session
      )

      socket =
        socket
        |> refresh_observation(browser_session)
        |> assign(error_message: nil)

      {:reply, %{"ok" => true}, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_tool_registered", params, socket),
    do: handle_registry_lifecycle(:tool_registered, params, socket)

  @impl true
  def handle_event("webmcp_tool_unregistered", params, socket),
    do: handle_registry_lifecycle(:tool_unregistered, params, socket)

  @impl true
  def handle_event("webmcp_session_disconnected", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket) do
      InvocationRunner.cancel_open!(socket.assigns.room,
        browser_session_id: browser_session.id,
        invocation_epoch: socket.assigns.room.invocation_epoch
      )

      browser_session =
        Domain.disconnect_browser_session!(browser_session, %{disconnected_at: DateTime.utc_now()})

      {:noreply,
       socket
       |> cancel_invocations(:disconnected)
       |> refresh(browser_session)
       |> assign(error_message: nil)}
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_invocation_begin", params, socket) do
    room = socket.assigns.room
    revision = socket.assigns.active_tool

    with :ok <- valid_room_event?(params, room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         :ok <- browser_session_connected?(browser_session),
         :ok <- invocation_revision_matches?(params, revision),
         :ok <- invocation_epoch_matches?(params, room),
         {:ok, arguments} <- invocation_arguments(params) do
      request_uuid = value(params, "request_uuid") || Ash.UUID.generate()

      try do
        invocation =
          InvocationRunner.begin!(room, browser_session, revision, arguments,
            request_uuid: request_uuid,
            invocation_epoch: room.invocation_epoch
          )

        {:reply,
         %{
           "invocation_id" => invocation.id,
           "request_uuid" => invocation.request_uuid,
           "effective_status" => to_string(invocation.effective_status)
         }, socket}
      rescue
        error ->
          message = readable_error(error)
          {:reply, %{"error" => message}, assign(socket, error_message: message)}
      end
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_execute", %{"invocation_id" => invocation_id} = params, socket) do
    room = socket.assigns.room

    with {:ok, invocation} <- room_invocation(invocation_id, room),
         :ok <- invocation_epoch_matches?(params, room),
         :ok <- invocation_epoch_matches?(invocation, room) do
      execute_reply(socket, invocation, room)
    else
      {:error, message} ->
        {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  def handle_event("webmcp_execute", _params, socket),
    do:
      {:reply, %{"error" => "invocation_id is required"},
       assign(socket, error_message: "invocation_id is required")}

  @impl true
  def handle_event("webmcp_invocation_cancel", params, socket) do
    room = socket.assigns.room

    with {:ok, invocation} <- room_invocation(value(params, "invocation_id"), room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         :ok <- invocation_browser_session_matches?(invocation, browser_session),
         :ok <- invocation_epoch_matches?(params, room),
         :ok <- invocation_epoch_matches?(invocation, room) do
      invocation = InvocationRunner.cancel!(invocation)
      {:reply, %{"effective_status" => to_string(invocation.effective_status)}, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_poststate_observed", params, socket) do
    room = socket.assigns.room

    with :ok <- valid_room_event?(params, room),
         {:ok, invocation} <- room_invocation(value(params, "invocation_id"), room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         :ok <- browser_session_connected?(browser_session),
         :ok <- invocation_browser_session_matches?(invocation, browser_session),
         :ok <- invocation_epoch_matches?(params, room),
         :ok <- invocation_epoch_matches?(invocation, room),
         {:ok, post_state} <- post_state(params) do
      invocation =
        if invocation.effective_status in [:verified_failure, :verified_success] do
          invocation
        else
          InvocationRunner.verify!(invocation, post_state)
        end

      socket =
        socket
        |> refresh(browser_session)
        |> assign(error_message: nil)

      {:reply, invocation_reply(invocation, socket.assigns.active_tool, socket.assigns.room),
       socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("update_source", params, socket) do
    source = value(params, "source_markdown") || value(params, "source")

    if is_binary(source) do
      put_source(socket, source, :editor)
    else
      {:noreply, assign(socket, error_message: "Source Skill text is required")}
    end
  end

  @impl true
  def handle_event("validate_skill_upload", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  @impl true
  def handle_event("upload_skill", _params, socket) do
    case consume_skill_upload(socket) do
      {:ok, source} -> put_source(assign(socket, upload_error: nil), source, :upload)
      {:error, message} -> {:noreply, assign(socket, upload_error: message)}
    end
  end

  @impl true
  def handle_event("request_repair", _params, socket) do
    case start_repair(socket) do
      {:repair_requested, _detail, socket} -> {:noreply, socket}
      {_status, detail, socket} -> {:noreply, assign(socket, error_message: detail)}
    end
  end

  @impl true
  def handle_event("webmcp_request_repair", params, socket) do
    case valid_room_event?(params, socket.assigns.room) do
      :ok ->
        case start_repair(socket) do
          {:error, message, socket} ->
            {:reply, %{"error" => message}, assign(socket, error_message: message)}

          {status, detail, socket} ->
            {:reply,
             %{
               "status" => to_string(status),
               "detail" => detail,
               "tool_can_publish" => false
             }, socket}
        end

      {:error, message} ->
        {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("approve_repair", _params, socket) do
    case socket.assigns.proposal do
      %RepairProposal{} = proposal ->
        try do
          published = RepairApprovalService.approve_and_publish!(proposal, "owner")

          socket =
            socket
            |> refresh(socket.assigns.browser_session)
            |> assign(error_message: nil)
            |> push_publication_requested(published)
            |> push_desired_toolset()

          {:noreply, socket}
        rescue
          error -> {:noreply, assign(socket, error_message: readable_error(error))}
        end

      nil ->
        {:noreply, assign(socket, error_message: @no_proposal)}
    end
  end

  @impl true
  def handle_event("reject_repair", _params, socket) do
    case socket.assigns.proposal do
      %RepairProposal{} = proposal ->
        try do
          RepairApprovalService.reject!(proposal)

          {:noreply,
           socket |> refresh(socket.assigns.browser_session) |> assign(error_message: nil)}
        rescue
          error -> {:noreply, assign(socket, error_message: readable_error(error))}
        end

      nil ->
        {:noreply, assign(socket, error_message: @no_proposal)}
    end
  end

  @impl true
  def handle_event("retry_original_goal", _params, socket) do
    with {:ok, invocation} <- latest_failed_invocation(socket.assigns.room),
         %BrowserSession{} = browser_session <- socket.assigns.browser_session do
      try do
        retried = InvocationRunner.retry!(invocation, browser_session)

        socket =
          socket
          |> refresh(browser_session)
          |> assign(error_message: nil)
          |> push_ui_retry_started(retried)

        {:noreply, socket}
      rescue
        error -> {:noreply, assign(socket, error_message: readable_error(error))}
      end
    else
      {:error, message} ->
        {:noreply, assign(socket, error_message: message)}

      _ ->
        {:noreply,
         assign(socket, error_message: "Connect a WebMCP browser session before retrying")}
    end
  end

  def handle_event("verify_goal", params, socket) do
    case room_invocation(value(params, "invocation_id"), socket.assigns.room) do
      {:ok, invocation} ->
        try do
          verified =
            if invocation.effective_status in [:verified_failure, :verified_success] do
              invocation
            else
              InvocationRunner.verify!(invocation, post_state_from_assigns(socket.assigns))
            end

          {:noreply,
           socket
           |> refresh(socket.assigns.browser_session)
           |> assign(
             error_message:
               if(verified.effective_status == :verified_success,
                 do: nil,
                 else: "Goal is not verified yet"
               )
           )}
        rescue
          error -> {:noreply, assign(socket, error_message: readable_error(error))}
        end

      {:error, message} ->
        {:noreply, assign(socket, error_message: message)}
    end
  end

  # Reset throws away the room's whole record, so it is asked for in the page
  # rather than in a browser dialog: the button becomes the question, and only
  # the second click resets.
  @impl true
  def handle_event("ask_reset_demo", _params, socket) do
    {:noreply, assign(socket, confirming_reset: true)}
  end

  @impl true
  def handle_event("keep_room", _params, socket) do
    {:noreply, assign(socket, confirming_reset: false)}
  end

  @impl true
  def handle_event("reset_demo", _params, socket) do
    {socket, repair_key} = invalidate_repair(socket)
    socket = cancel_invocations(socket, :reset)

    try do
      room = DemoReset.reset!(socket.assigns.room)

      :ok =
        Phoenix.PubSub.broadcast_from(
          Patchbay.PubSub,
          self(),
          Room.topic(room.id),
          {:patchbay_room_reset, room.id, room.invocation_epoch}
        )

      socket =
        socket
        |> apply_room_reset(room.invocation_epoch)
        |> cancel_repair(repair_key)

      {:noreply, socket}
    rescue
      error ->
        {:noreply,
         socket
         |> cancel_repair(repair_key)
         |> assign(error_message: readable_error(error))}
    end
  end

  # A repair published by the worker that answered a report reaches the page the
  # same way the owner's own click does: the room is re-read, and the browser is
  # asked to swap the tool it is offering.
  @impl true
  def handle_info({:patchbay_agent_published, room_id, proposal_id}, socket)
      when room_id == socket.assigns.room.id do
    socket = refresh(socket, socket.assigns.browser_session)

    case room_proposal(proposal_id, socket.assigns.room) do
      %RepairProposal{} = proposal ->
        {:noreply,
         socket
         |> assign(error_message: nil)
         |> push_publication_requested(proposal)
         |> push_desired_toolset()}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:patchbay_agent_replied, room_id, _report_id}, socket)
      when room_id == socket.assigns.room.id do
    {:noreply, refresh(socket, socket.assigns.browser_session)}
  end

  # Each step of a repair the worker is running arrives here while it is still
  # running, so the card moves through the work instead of jumping from waiting
  # straight to finished.
  @impl true
  def handle_info({:patchbay_agent_progress, room_id, _phase}, socket)
      when room_id == socket.assigns.room.id do
    {:noreply, refresh(socket, socket.assigns.browser_session)}
  end

  @impl true
  def handle_info({:patchbay_room_reset, room_id, epoch}, socket)
      when room_id == socket.assigns.room.id do
    {:noreply,
     socket
     |> invalidate_repair_for_reset()
     |> cancel_invocations(:reset)
     |> apply_room_reset(epoch)}
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:browser_session] do
      %BrowserSession{} = browser_session ->
        InvocationRunner.cancel_open!(socket.assigns.room,
          browser_session_id: browser_session.id,
          invocation_epoch: socket.assigns.room.invocation_epoch
        )

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_async({:repair, token}, {:ok, {:repair_result, token, {:ok, _proposal}}}, socket) do
    if repair_current?(socket, token) do
      {:noreply,
       socket
       |> refresh(socket.assigns.browser_session)
       |> assign(pending_operation: nil, repair_token: nil, error_message: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        {:repair, token},
        {:ok, {:repair_result, token, {:error, reason}}},
        socket
      ) do
    if repair_current?(socket, token) do
      handle_repair_failure(socket, readable_error(reason))
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:repair, token}, {:exit, reason}, socket) do
    if repair_current?(socket, token) do
      handle_repair_failure(socket, readable_error(reason))
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:invocation, epoch, request_uuid} = key, {:ok, {:ok, invocation}}, socket) do
    if invocation_current?(socket, key, epoch) do
      browser_session = Domain.get_browser_session!(invocation.browser_session_id)
      revision = Domain.get_tool_revision!(invocation.tool_revision_id)

      {:noreply,
       socket
       |> finish_invocation(key)
       |> refresh(browser_session)
       |> assign(error_message: nil)
       |> push_invocation_result(invocation, revision, request_uuid, epoch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:invocation, epoch, request_uuid} = key, {:ok, {:error, reason}}, socket) do
    if invocation_current?(socket, key, epoch) do
      message = readable_error(reason)

      {:noreply,
       socket
       |> finish_invocation(key)
       |> assign(error_message: message)
       |> push_invocation_error(request_uuid, message, epoch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:invocation, epoch, request_uuid} = key, {:exit, reason}, socket) do
    if invocation_current?(socket, key, epoch) do
      message = readable_error(reason)

      {:noreply,
       socket
       |> finish_invocation(key)
       |> assign(error_message: message)
       |> push_invocation_error(request_uuid, message, epoch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(_key, _result, socket), do: {:noreply, socket}

  defp execute_reply(socket, %Invocation{effective_status: :started} = invocation, room) do
    key = {:invocation, room.invocation_epoch, invocation.request_uuid}

    {:reply,
     %{
       "accepted" => true,
       "invocation_id" => invocation.id,
       "request_uuid" => invocation.request_uuid
     }, run_invocation(socket, invocation, key)}
  end

  defp execute_reply(socket, invocation, room) do
    revision = Domain.get_tool_revision!(invocation.tool_revision_id)
    {:reply, invocation_reply(invocation, revision, room), socket}
  end

  # A call runs once. The browser is free to ask again, and asking again while
  # the first run is still going is answered without starting a second one.
  defp run_invocation(socket, invocation, key) do
    if MapSet.member?(socket.assigns.invocation_keys, key) do
      socket
    else
      fallback? = Config.demo_fallback?()

      socket
      |> update(:invocation_keys, &MapSet.put(&1, key))
      |> start_async(key, fn ->
        try do
          {:ok, InvocationRunner.execute!(invocation, fallback: fallback?)}
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)
    end
  end

  # The owner's button and the agent's request both come through here, so a room
  # can only ever have one diagnosis running, and the spend limits inside
  # RepairPlanner apply to a tool-triggered request exactly as to a click.
  # Neither caller can approve or publish: this only produces a proposal.
  defp start_repair(socket) do
    proposal = socket.assigns.proposal

    cond do
      socket.assigns.pending_operation == :repair or socket.assigns.room.status == :diagnosing ->
        {:already_in_progress, "Patchbay is already working out a repair for this room.", socket}

      match?(%RepairProposal{status: :ready_for_approval}, proposal) ->
        {:proposal_ready,
         "A repair is already proposed and waiting to be approved. This tool cannot approve it.",
         socket}

      is_nil(proposal) and socket.assigns.room.status == :failed ->
        repair_failed_call(socket)

      socket.assigns.room.status == :error ->
        {:no_failed_invocation,
         "The last repair attempt did not complete. A person has to reset the demo before another repair can be asked for.",
         socket}

      true ->
        {:no_failed_invocation, "This room has no failed tool call waiting for a repair.", socket}
    end
  end

  defp repair_failed_call(socket) do
    case latest_failed_invocation(socket.assigns.room) do
      {:ok, invocation} -> begin_repair(socket, invocation)
      {:error, detail} -> {:no_failed_invocation, detail, socket}
    end
  end

  defp begin_repair(socket, invocation) do
    Domain.begin_diagnosis!(socket.assigns.room)
    repair_token = Ash.UUID.generate()

    socket =
      socket
      |> refresh(socket.assigns.browser_session)
      |> assign(error_message: nil, pending_operation: :repair, repair_token: repair_token)
      |> start_async({:repair, repair_token}, fn ->
        result =
          try do
            {:ok, RepairPlanner.propose!(invocation, fallback: Config.demo_fallback?())}
          rescue
            error -> {:error, error}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        {:repair_result, repair_token, result}
      end)

    {:repair_requested,
     "Patchbay is working out a repair. This tool cannot approve or publish one; asking is all it does.",
     socket}
  rescue
    error -> {:error, readable_error(error), socket}
  end

  defp handle_repair_failure(socket, message) do
    socket =
      try do
        room = Domain.mark_repair_failed!(socket.assigns.room)
        append_event(room, :platform_error, %{"operation" => "repair", "error" => message})
        refresh(socket, socket.assigns.browser_session)
      rescue
        _ -> socket
      end

    {:noreply, assign(socket, pending_operation: nil, repair_token: nil, error_message: message)}
  end

  defp put_source(socket, source, origin) do
    case accepted_source(socket, source) do
      {:ok, source} -> commit_source(socket, source, origin)
      {:error, message} -> {:noreply, report_source_problem(socket, origin, message)}
    end
  end

  defp commit_source(socket, source, origin) do
    Domain.update_source!(socket.assigns.room, source)

    {:noreply,
     socket
     |> refresh(socket.assigns.browser_session)
     |> assign(error_message: nil, upload_error: nil)}
  rescue
    error -> {:noreply, report_source_problem(socket, origin, readable_error(error))}
  end

  # An uploaded file is rejected beside the upload control; pasted text is
  # rejected in the page banner above the editors.
  defp report_source_problem(socket, :upload, message),
    do: assign(socket, upload_error: message)

  defp report_source_problem(socket, :editor, message),
    do: assign(socket, error_message: message)

  # The room only accepts Skill text while it is ready, and the same characters
  # Patchbay refuses in a generated candidate are refused on the way in. Both
  # controls are disabled outside the ready state, so this is what a forged
  # event meets.
  defp accepted_source(socket, source) do
    cond do
      socket.assigns.room.status != :ready ->
        {:error,
         "The Source Skill is locked while this room is working. Reset the demo to edit it again."}

      not String.valid?(source) ->
        {:error, "That Skill text is not readable. Use plain Markdown saved as UTF-8."}

      CandidateGenerator.unsupported_characters(source) == :nul ->
        {:error,
         "That Skill text contains characters Patchbay cannot store. Remove them and try again."}

      CandidateGenerator.unsupported_characters(source) == :hidden_unicode ->
        {:error,
         "That Skill text contains hidden characters that do not show on screen. Remove them and try again."}

      true ->
        {:ok, source}
    end
  end

  # The uploaded file feeds the same source update as pasting, so the digest and
  # the timeline event are produced by exactly one path.
  defp consume_skill_upload(socket) do
    case uploaded_entries(socket, :skill) do
      {[_entry], []} ->
        socket
        |> consume_uploaded_entries(:skill, fn %{path: path}, _entry ->
          {:ok, readable_markdown(File.read(path))}
        end)
        |> List.first()

      {[], []} ->
        {:error, "Choose a Markdown Skill file before uploading."}

      {_done, [_ | _]} ->
        {:error, "That file was not accepted. Upload one Markdown Skill of 64 KB or less."}
    end
  end

  defp readable_markdown({:ok, content}) do
    cond do
      not String.valid?(content) ->
        {:error, "That file is not readable text. Upload a Markdown Skill saved as UTF-8."}

      String.trim(content) == "" ->
        {:error, "That file is empty. Upload a Markdown Skill with content in it."}

      true ->
        {:ok, content}
    end
  end

  defp readable_markdown({:error, _reason}),
    do: {:error, "That file could not be read. Try uploading it again."}

  # Everything on the page, read off the room the page was read with. Only the
  # board's reports and the repair the Patchbay Agent is running belong to
  # somebody else's record and come from their own reads.
  defp assigns_for(%Room{} = room, browser_session) do
    invocation = room.latest_invocation
    proposal = room.active_repair_proposal

    %{
      room: room,
      browser_session: browser_session,
      timeline: RoomTimeline.list!(room.id),
      source_bytes: Digest.artifact_size(room.source_markdown),
      candidate_bytes:
        if(is_binary(room.candidate_markdown),
          do: Digest.artifact_size(room.candidate_markdown),
          else: 0
        ),
      invocation: invocation,
      invocation_revision: invocation && invocation.tool_revision,
      active_tool: room.desired_tool_revision,
      proposal: proposal,
      proposal_source_revision: proposal && proposal.source_tool_revision,
      proposal_candidate_revision: proposal && proposal.candidate_tool_revision,
      agent_attempt: latest_agent_attempt(room),
      room_reports: Board.reports_for_room(room.id)
    }
  end

  # How far the Patchbay Agent has got with the repair of the call this room is
  # waiting on. Keying it on the call rather than on the room is what keeps a
  # finished repair off a room that has since been reset, because a reset clears
  # the call.
  defp latest_agent_attempt(%Room{last_failed_invocation_id: nil}), do: nil

  defp latest_agent_attempt(%Room{last_failed_invocation_id: invocation_id}) do
    # The record is Patchbay's own bookkeeping that no actor may read, and the
    # room the call belongs to is the one place it is shown, so the read is made
    # deliberately without an actor.
    Forum.latest_repair_attempt_for_call!(invocation_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp refresh(socket, browser_session) do
    room = Domain.get_room_by_id!(socket.assigns.room.id, load: @page_loads)
    assign(socket, assigns_for(room, reload_browser_session(browser_session)))
  end

  # A browser reporting which tools it is offering moves the session it reported
  # from and the one timeline entry it appended, and nothing else, so that is
  # all these re-read.
  defp refresh_observation(socket, browser_session) do
    assign(socket,
      browser_session: browser_session,
      timeline: RoomTimeline.list!(socket.assigns.room.id)
    )
  end

  defp reload_browser_session(nil), do: nil

  defp reload_browser_session(%BrowserSession{id: id}) do
    Domain.get_browser_session!(id)
  rescue
    _ -> nil
  end

  # Rooms are created by PatchbayWeb.RoomController when a visitor arrives,
  # already offering their generation-1 tool. A slug that resolves to nothing is
  # simply not a room; any other failure is a real error and stays visible.
  defp load_room!(slug) do
    case Domain.get_room_by_slug!(slug, load: @page_loads, not_found_error?: false) do
      %Room{} = room -> room
      nil -> raise Ash.Error.Query.NotFound.exception(resource: Room)
    end
  end

  defp latest_failed_invocation(%Room{last_failed_invocation_id: id} = room)
       when is_binary(id) do
    case room_invocation(id, room) do
      {:ok, %Invocation{effective_status: :verified_failure} = invocation} -> {:ok, invocation}
      _ -> {:error, "There is no verified failure to repair yet"}
    end
  end

  defp latest_failed_invocation(%Room{}),
    do: {:error, "Run the seeded tool first; its visible postcondition must fail before repair"}

  # A call named by the browser is this room's call only if the room says so, so
  # the room is part of the lookup rather than a comparison made after it.
  defp room_invocation(id, %Room{} = room) when is_binary(id) do
    case Domain.get_room_invocation(id, room.id, not_found_error?: false) do
      {:ok, %Invocation{} = invocation} -> {:ok, invocation}
      _ -> {:error, "that call does not belong to this room"}
    end
  end

  defp room_invocation(_id, %Room{}), do: {:error, "invocation_id is required"}

  # The repair a message from outside this process names, if it is this room's.
  defp room_proposal(id, %Room{} = room) do
    case Domain.get_room_repair_proposal(id, room.id, not_found_error?: false) do
      {:ok, %RepairProposal{} = proposal} -> proposal
      _ -> nil
    end
  end

  defp register_browser_session(room, params, client_instance_id, forum_session_id) do
    attrs = %{
      room_id: room.id,
      client_instance_id: client_instance_id,
      forum_session_id: forum_session_id,
      user_agent_digest: user_agent_digest(params),
      webmcp_supported: value(params, "webmcp_supported") == true
    }

    {:ok, Domain.register_browser_session!(attrs)}
  rescue
    error -> {:error, readable_error(error)}
  end

  defp browser_session_for(params, socket) do
    id = value(params, "browser_session_id")

    candidate =
      cond do
        is_binary(id) ->
          id

        match?(%BrowserSession{}, socket.assigns.browser_session) ->
          socket.assigns.browser_session.id

        true ->
          nil
      end

    with true <- is_binary(candidate),
         {:ok, browser_session} <- fetch_browser_session(candidate),
         true <- browser_session.room_id == socket.assigns.room.id do
      {:ok, browser_session}
    else
      false -> {:error, "browser session belongs to another room"}
      {:error, _} -> {:error, "browser session is not registered for this room"}
      _ -> {:error, "browser_session_id is required"}
    end
  end

  defp fetch_browser_session(id) do
    {:ok, Domain.get_browser_session!(id)}
  rescue
    _ -> {:error, :not_found}
  end

  defp invocation_browser_session_matches?(
         %Invocation{browser_session_id: invocation_session_id},
         %BrowserSession{id: browser_session_id}
       )
       when invocation_session_id == browser_session_id,
       do: :ok

  defp invocation_browser_session_matches?(_invocation, _browser_session),
    do: {:error, "post-state observation must come from the invocation browser session"}

  defp browser_session_connected?(%BrowserSession{disconnected_at: nil}), do: :ok

  defp browser_session_connected?(_browser_session),
    do: {:error, "browser session is disconnected"}

  # What a browser says it is offering, checked in the order a wrong report
  # fails: the generation it answered for, the shape of what it sent, then
  # whether the toolset is Patchbay's own.
  defp registry_attributes(params, %{room: room, active_tool: revision}, mode) do
    generation = value(params, "observed_generation")
    names = value(params, "observed_tool_names") || []
    contracts = value(params, "observed_contracts") || %{}

    with :ok <- observed_generation_current?(generation, room),
         :ok <- observed_names_readable?(names),
         :ok <- observed_contracts_readable?(contracts, names),
         :ok <- observed_toolset_owned?(names, contracts, revision, mode) do
      {:ok,
       %{
         webmcp_supported: true,
         desired_generation: room.desired_tool_generation,
         observed_generation: generation,
         observed_tool_names: names,
         observed_contracts: contracts,
         last_seen_at: DateTime.utc_now()
       }}
    end
  end

  defp observed_generation_current?(generation, room) do
    if generation == room.desired_tool_generation,
      do: :ok,
      else: {:error, "observed_generation must match the room's desired generation"}
  end

  defp observed_names_readable?(names) do
    cond do
      not is_list(names) or Enum.any?(names, &(not is_binary(&1))) or
          length(names) > @max_observed_tool_names ->
        {:error, "observed_tool_names must be a list of names"}

      length(names) != MapSet.size(MapSet.new(names)) ->
        {:error, "observed_tool_names must not contain duplicates"}

      true ->
        :ok
    end
  end

  defp observed_contracts_readable?(contracts, names) do
    cond do
      not is_map(contracts) or Enum.any?(contracts, &unreadable_contract?/1) ->
        {:error, "observed_contracts must map tool names to SHA-256 digests"}

      MapSet.new(Map.keys(contracts)) != MapSet.new(names) ->
        {:error, "observed contracts must exactly cover the observed tool names"}

      true ->
        :ok
    end
  end

  defp unreadable_contract?({name, digest}) do
    not is_binary(name) or not is_binary(digest) or not Regex.match?(@sha256_regex, digest)
  end

  defp observed_toolset_owned?(names, contracts, revision, mode) do
    observed = MapSet.new(names)
    expected = MapSet.new(@permanent_tool_names ++ [revision.name])

    cond do
      not MapSet.subset?(observed, expected) ->
        {:error, "observed registry contains a tool Patchbay does not own"}

      mode == :reconciled and observed != expected ->
        {:error, "reconciled registry must contain the complete desired Patchbay toolset"}

      MapSet.member?(observed, revision.name) and
          Map.get(contracts, revision.name) != revision.contract_sha256 ->
        {:error, "observed tool contract does not match the desired revision"}

      true ->
        :ok
    end
  end

  defp invocation_revision_matches?(params, revision) do
    if value(params, "tool_name") == revision.name and
         value(params, "contract_sha256") == revision.contract_sha256 do
      :ok
    else
      {:error, "invoked tool name and contract must match the current desired revision"}
    end
  end

  defp invocation_epoch_matches?(%Invocation{invocation_epoch: epoch}, room) do
    if epoch == room.invocation_epoch,
      do: :ok,
      else: {:error, "invocation belongs to an earlier room lifecycle"}
  end

  defp invocation_epoch_matches?(params, room) do
    case value(params, "invocation_epoch") do
      nil when room.invocation_epoch == 0 -> :ok
      epoch when epoch == room.invocation_epoch -> :ok
      _ -> {:error, "invocation belongs to an earlier room lifecycle"}
    end
  end

  defp invocation_arguments(params) do
    arguments = value(params, "arguments") || %{}

    if is_map(arguments),
      do: {:ok, arguments},
      else: {:error, "invocation arguments must be an object"}
  end

  defp post_state(params) do
    state = value(params, "post_state") || %{}
    if is_map(state), do: {:ok, state}, else: {:error, "post_state must be an object"}
  end

  defp post_state_from_assigns(assigns) do
    %{
      "ui_revision" => assigns.room.ui_revision,
      "source" => %{"present" => true, "sha256" => assigns.room.source_sha256},
      "candidate" => %{
        "present" => is_binary(assigns.room.candidate_markdown),
        "sha256" => assigns.room.candidate_sha256
      }
    }
  end

  defp invocation_reply(invocation, revision, room) do
    %{
      "invocation_id" => invocation.id,
      "effective_status" => to_string(invocation.effective_status),
      "failure_code" => if(invocation.failure_code, do: to_string(invocation.failure_code)),
      "handler_reported_success" => invocation.handler_reported_success,
      "handler_result" => invocation.handler_result,
      "patchbay_receipt" => invocation.receipt,
      # The same receipt again, under the name of the thing to do with it, so an
      # agent reading this result cannot miss the one value a report needs.
      "report_this_call" => %{"receipt" => invocation.receipt},
      "patchbay_verification" => verification_reply(invocation),
      "next_action" => invocation_next_action(invocation),
      "expected_ui_revision" => room.ui_revision,
      "ui_commit_required" => revision.handler_adapter == :apply_candidate_to_editor
    }
  end

  defp verification_reply(invocation) do
    case Domain.list_verifications!(query: [filter: [invocation_id: invocation.id], limit: 1]) do
      [verification | _] ->
        %{
          "passed" => verification.passed,
          "failure_code" =>
            if(verification.failure_code, do: to_string(verification.failure_code)),
          "checks" => verification.checks,
          "expected" => verification.expected_state,
          "observed" => verification.observed_state
        }

      [] ->
        nil
    end
  end

  defp invocation_next_action(%Invocation{effective_status: :verified_failure}),
    do: "Call report_tool_problem with receipt set to the patchbay_receipt value in this result."

  defp invocation_next_action(%Invocation{effective_status: :verified_success}),
    do: "The goal is verified; nothing more to do."

  defp invocation_next_action(_invocation), do: "Wait for visible-state verification."

  defp push_invocation_result(socket, invocation, revision, request_uuid, epoch) do
    push_event(
      socket,
      "patchbay:#{socket.assigns.room.id}:invocation_result",
      invocation
      |> invocation_reply(revision, socket.assigns.room)
      |> Map.put("request_uuid", request_uuid)
      |> Map.put("invocation_epoch", epoch)
    )
  end

  defp push_invocation_error(socket, request_uuid, message, epoch) do
    push_event(socket, "patchbay:#{socket.assigns.room.id}:invocation_result", %{
      "request_uuid" => request_uuid,
      "invocation_epoch" => epoch,
      "error" => message
    })
  end

  defp push_ui_retry_started(socket, invocation) do
    push_event(
      socket,
      "patchbay:#{socket.assigns.room.id}:ui_retry_started",
      invocation_reply(invocation, socket.assigns.active_tool, socket.assigns.room)
      |> Map.put("invocation_epoch", socket.assigns.invocation_epoch)
    )
  end

  defp push_publication_requested(socket, proposal) do
    room = socket.assigns.room

    push_event(socket, "patchbay:#{room.id}:publication_requested", %{
      "room_id" => room.id,
      "proposal_id" => proposal.id,
      "retire_before_register" => proposal.source_tool_revision_id,
      "revision" => revision_payload(socket.assigns.active_tool)
    })
  end

  defp push_desired_toolset(socket) do
    room = socket.assigns.room

    push_event(socket, "patchbay:#{room.id}:desired_toolset", %{
      "room_id" => room.id,
      "generation" => room.desired_tool_generation,
      "permanent_tools" => @permanent_tool_names,
      "revisions" => [revision_payload(socket.assigns.active_tool)]
    })
  end

  defp revision_payload(revision) do
    %{
      "id" => revision.id,
      "name" => revision.name,
      "title" => revision.title,
      "description" => revision.description,
      "input_schema" => revision.input_schema,
      "annotations" => revision.annotations,
      "handler_adapter" => to_string(revision.handler_adapter),
      "output_contract" => revision.output_contract,
      "postcondition_set" => to_string(revision.postcondition_set),
      "contract_sha256" => revision.contract_sha256,
      "generation" => revision.generation
    }
  end

  defp append_event(room, kind, payload, browser_session \\ nil)

  defp append_event(room, kind, payload, %BrowserSession{id: id}),
    do: RoomTimeline.append!(room, kind, payload, browser_session_id: id)

  defp append_event(room, kind, payload, _), do: RoomTimeline.append!(room, kind, payload)

  defp handle_registry_lifecycle(kind, params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         {:ok, payload} <- lifecycle_payload(params) do
      append_event(socket.assigns.room, kind, payload, browser_session)

      socket =
        socket
        |> refresh_observation(browser_session)
        |> assign(error_message: nil)

      {:reply, %{"ok" => true}, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  defp lifecycle_payload(params) do
    name = value(params, "tool_name")
    generation = value(params, "generation")
    digest = value(params, "contract_sha256")

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "tool_name is required"}

      not is_integer(generation) or generation < 1 ->
        {:error, "generation must be positive"}

      not is_binary(digest) or byte_size(digest) != 64 ->
        {:error, "contract digest is invalid"}

      true ->
        {:ok,
         %{
           "tool_name" => name,
           "generation" => generation,
           "contract_sha256" => digest
         }}
    end
  end

  defp valid_room_event?(params, room) do
    room_id = room.id

    case value(params, "room_id") do
      nil -> :ok
      ^room_id -> :ok
      _ -> {:error, "event belongs to another room"}
    end
  end

  defp client_instance_id(params) do
    case value(params, "client_instance_id") do
      id when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, "client_instance_id must be a UUID"}
        end

      nil ->
        {:ok, Ash.UUID.generate()}

      _ ->
        {:error, "client_instance_id must be a UUID"}
    end
  end

  defp user_agent_digest(params) do
    case value(params, "user_agent_digest") do
      digest when is_binary(digest) and byte_size(digest) == 64 -> digest
      _ -> Digest.sha256("unknown-browser")
    end
  end

  defp value(params, key, default \\ nil)

  defp value(params, key, default) when is_map(params),
    do: Map.get(params, key, Map.get(params, String.to_atom(key), default))

  defp value(_params, _key, default), do: default

  defp invalidate_repair(socket) do
    case socket.assigns[:repair_token] do
      token when is_binary(token) ->
        {assign(socket, pending_operation: nil, repair_token: nil), {:repair, token}}

      _ ->
        {assign(socket, pending_operation: nil, repair_token: nil), nil}
    end
  end

  defp invalidate_repair_for_reset(socket) do
    {socket, repair_key} = invalidate_repair(socket)
    cancel_repair(socket, repair_key)
  end

  defp apply_room_reset(socket, epoch) do
    socket =
      socket
      |> refresh(socket.assigns.browser_session)
      |> assign(
        error_message: nil,
        upload_error: nil,
        confirming_reset: false,
        pending_operation: nil,
        repair_token: nil,
        invocation_epoch: epoch
      )

    socket
    |> push_event("patchbay:#{socket.assigns.room.id}:reset_browser_registry", %{
      "room_id" => socket.assigns.room.id,
      "invocation_epoch" => epoch
    })
    |> push_desired_toolset()
  end

  defp cancel_repair(socket, nil), do: socket
  defp cancel_repair(socket, key), do: cancel_async(socket, key, {:shutdown, :reset})

  defp cancel_invocations(socket, reason) do
    socket.assigns.invocation_keys
    |> Enum.reduce(socket, fn key, current ->
      cancel_async(current, key, {:shutdown, reason})
    end)
    |> assign(invocation_keys: MapSet.new())
  end

  # A reset cancels the calls it interrupted and forgets their keys, so a result
  # that belongs to an earlier lifecycle of this room has nothing left to match.
  defp invocation_current?(socket, key, epoch) do
    epoch == socket.assigns.invocation_epoch and
      MapSet.member?(socket.assigns.invocation_keys, key)
  end

  defp finish_invocation(socket, key) do
    update(socket, :invocation_keys, &MapSet.delete(&1, key))
  end

  defp repair_current?(socket, token) do
    socket.assigns[:pending_operation] == :repair and socket.assigns[:repair_token] == token
  end

  defp readable_error(%{__exception__: true} = error), do: Exception.message(error)
  defp readable_error({:shutdown, reason}), do: readable_error(reason)
  defp readable_error(reason) when is_binary(reason), do: reason
  defp readable_error(reason), do: inspect(reason)
end
