defmodule PatchbayWeb.WebMCP.RoomLive.Show do
  @moduledoc """
  The single-room Skill Uplift Studio.

  This LiveView is deliberately small: Phoenix owns the durable room state and
  the WebMCP island reports browser observations back through the event names
  below. Human repair approval remains a normal LiveView action; no browser
  tool can approve or publish a repair.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
    DemoReset,
    Digest,
    Fixtures,
    Invocation,
    InvocationRunner,
    RepairApprovalService,
    RepairPlanner,
    Room,
    RoomEvent,
    RoomTimeline
  }

  require Ash.Query

  @permanent_tool_names ["get_patchbay_room_state", "verify_skill_uplift_goal"]
  @sha256_regex ~r/\A[0-9a-f]{64}\z/

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    room = load_room!(slug)

    {:ok,
     socket
     |> assign(assigns_for(room, nil))
     |> assign(
       page_title: room.title,
       error_message: nil,
       pending_operation: nil,
       repair_token: nil
     )}
  end

  @impl true
  def handle_event("webmcp_bootstrap", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, client_instance_id} <- client_instance_id(params),
         {:ok, browser_session} <-
           register_browser_session(socket.assigns.room, params, client_instance_id) do
      room = socket.assigns.room

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
        |> refresh(browser_session)
        |> push_desired_toolset()
        |> assign(error_message: nil)

      {:reply,
       %{
         "browser_session_id" => browser_session.id,
         "client_instance_id" => browser_session.client_instance_id,
         "desired_generation" => socket.assigns.room.desired_tool_generation,
         "revisions" => [revision_payload(desired_revision!(socket.assigns.room))]
       }, socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_registry_reconciled", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         {:ok, attrs} <- registry_attributes(params, socket.assigns.room, :reconciled) do
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
        |> refresh(browser_session)
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
         {:ok, attrs} <- registry_attributes(params, socket.assigns.room, :toolchange) do
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
        |> refresh(browser_session)
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
      browser_session =
        Domain.disconnect_browser_session!(browser_session, %{disconnected_at: DateTime.utc_now()})

      {:noreply, socket |> refresh(browser_session) |> assign(error_message: nil)}
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("webmcp_invocation_begin", params, socket) do
    room = socket.assigns.room

    with :ok <- valid_room_event?(params, room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         {:ok, revision} <- desired_revision_for(room),
         :ok <- invocation_revision_matches?(params, revision),
         {:ok, arguments} <- invocation_arguments(params) do
      request_uuid = value(params, "request_uuid") || Ash.UUID.generate()

      try do
        invocation =
          InvocationRunner.invoke!(room, browser_session, revision, arguments,
            request_uuid: request_uuid,
            fallback: demo_fallback?()
          )

        socket =
          socket
          |> refresh(browser_session)
          |> assign(error_message: nil)
          |> push_invocation_result(invocation, revision)

        {:reply, invocation_reply(invocation, revision, socket.assigns.room), socket}
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
  def handle_event("webmcp_execute", %{"invocation_id" => invocation_id}, socket) do
    case fetch_invocation(invocation_id, socket.assigns.room) do
      {:ok, invocation} ->
        revision = desired_revision!(socket.assigns.room)
        socket = push_invocation_result(socket, invocation, revision)
        {:reply, invocation_reply(invocation, revision, socket.assigns.room), socket}

      {:error, message} ->
        {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  def handle_event("webmcp_execute", _params, socket),
    do:
      {:reply, %{"error" => "invocation_id is required"},
       assign(socket, error_message: "invocation_id is required")}

  @impl true
  def handle_event("webmcp_poststate_observed", params, socket) do
    with :ok <- valid_room_event?(params, socket.assigns.room),
         {:ok, invocation} <-
           fetch_invocation(value(params, "invocation_id"), socket.assigns.room),
         {:ok, browser_session} <- browser_session_for(params, socket),
         :ok <- invocation_browser_session_matches?(invocation, browser_session),
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

      {:reply,
       invocation_reply(invocation, desired_revision!(socket.assigns.room), socket.assigns.room),
       socket}
    else
      {:error, message} -> {:reply, %{"error" => message}, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("update_source", params, socket) do
    source = value(params, "source_markdown") || value(params, "source")

    if is_binary(source) do
      try do
        room = Domain.update_source!(socket.assigns.room, source)

        {:noreply,
         socket
         |> refresh(socket.assigns.browser_session)
         |> assign(room: room, error_message: nil)}
      rescue
        error -> {:noreply, assign(socket, error_message: readable_error(error))}
      end
    else
      {:noreply, assign(socket, error_message: "Source Skill text is required")}
    end
  end

  @impl true
  def handle_event("request_repair", _params, socket) do
    with {:ok, invocation} <- latest_failed_invocation(socket.assigns.room) do
      try do
        Domain.begin_diagnosis!(socket.assigns.room)
        repair_token = Ash.UUID.generate()

        socket =
          socket
          |> refresh(socket.assigns.browser_session)
          |> assign(
            error_message: nil,
            pending_operation: :repair,
            repair_token: repair_token
          )

        {:noreply,
         start_async(socket, {:repair, repair_token}, fn ->
           result =
             try do
               {:ok, RepairPlanner.propose!(invocation, fallback: demo_fallback?())}
             rescue
               error -> {:error, error}
             catch
               kind, reason -> {:error, {kind, reason}}
             end

           {:repair_result, repair_token, result}
         end)}
      rescue
        error -> {:noreply, assign(socket, error_message: readable_error(error))}
      end
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("approve_repair", _params, socket) do
    with {:ok, proposal} <- active_proposal(socket.assigns.room) do
      try do
        published = RepairApprovalService.approve_and_publish!(proposal, "owner")
        room = Domain.get_room_by_id!(socket.assigns.room.id)

        socket =
          socket
          |> refresh(socket.assigns.browser_session)
          |> assign(error_message: nil)
          |> push_publication_requested(published, room)
          |> push_desired_toolset()

        {:noreply, socket}
      rescue
        error -> {:noreply, assign(socket, error_message: readable_error(error))}
      end
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("reject_repair", _params, socket) do
    with {:ok, proposal} <- active_proposal(socket.assigns.room) do
      try do
        RepairApprovalService.reject!(proposal)

        {:noreply,
         socket |> refresh(socket.assigns.browser_session) |> assign(error_message: nil)}
      rescue
        error -> {:noreply, assign(socket, error_message: readable_error(error))}
      end
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
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
          |> push_invocation_result(retried, desired_revision!(socket.assigns.room))

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
    with {:ok, invocation} <-
           fetch_invocation(value(params, "invocation_id"), socket.assigns.room) do
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
    else
      {:error, message} -> {:noreply, assign(socket, error_message: message)}
    end
  end

  @impl true
  def handle_event("reset_demo", _params, socket) do
    {socket, repair_key} = invalidate_repair(socket)

    try do
      room = DemoReset.reset!(socket.assigns.room)
      browser_session = reload_browser_session(socket.assigns.browser_session)

      socket =
        socket
        |> refresh(browser_session)
        |> assign(error_message: nil, pending_operation: nil, repair_token: nil)
        |> push_event("patchbay:#{room.id}:reset_browser_registry", %{"room_id" => room.id})
        |> push_desired_toolset()
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
  def handle_async(_key, _result, socket), do: {:noreply, socket}

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

  defp assigns_for(%Room{} = room, browser_session) do
    invocation = latest_invocation(room)
    proposal = latest_proposal(room)

    %{
      room: room,
      browser_session: browser_session,
      invocation: invocation,
      invocation_revision: invocation_revision(invocation),
      proposal: proposal,
      timeline: RoomTimeline.list!(room.id),
      source_bytes: Digest.artifact_size(room.source_markdown),
      candidate_bytes:
        if(is_binary(room.candidate_markdown),
          do: Digest.artifact_size(room.candidate_markdown),
          else: 0
        )
    }
  end

  defp refresh(socket, browser_session) do
    room = Domain.get_room_by_id!(socket.assigns.room.id)
    browser_session = reload_browser_session(browser_session)
    assign(socket, assigns_for(room, browser_session))
  end

  defp reload_browser_session(nil), do: nil

  defp reload_browser_session(%BrowserSession{id: id}) do
    Domain.get_browser_session!(id)
  rescue
    _ -> nil
  end

  defp load_room!(slug) do
    case Domain.list_rooms!(query: [filter: [slug: slug], limit: 1]) do
      [room | _] ->
        ensure_seed_revision!(room)

      [] ->
        if slug == Fixtures.slug() do
          room = Domain.create_seeded_room!()
          ensure_seed_revision!(room)
        else
          raise Ash.Error.Query.NotFound.exception(resource: Room)
        end
    end
  end

  defp ensure_seed_revision!(room) do
    case Domain.list_tool_revisions!(
           query: [filter: [room_id: room.id, status: :desired], limit: 1]
         ) do
      [_revision | _] ->
        room

      [] ->
        Fixtures.revision_attributes(room.id)
        |> Map.delete(:contract_sha256)
        |> Domain.create_tool_revision!()

        Domain.get_room_by_id!(room.id)
    end
  end

  defp desired_revision_for(room) do
    {:ok, desired_revision!(room)}
  rescue
    error -> {:error, readable_error(error)}
  end

  defp desired_revision!(room) do
    case Domain.list_tool_revisions!(
           query: [
             filter: [
               room_id: room.id,
               generation: room.desired_tool_generation,
               status: :desired
             ],
             limit: 1
           ]
         ) do
      [revision | _] -> revision
      [] -> raise ArgumentError, "room has no desired tool revision"
    end
  end

  defp latest_invocation(%Room{} = room) do
    case Domain.list_invocations!(
           query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
         ) do
      [invocation | _] -> invocation
      [] -> nil
    end
  rescue
    _ -> nil
  end

  defp invocation_revision(nil), do: nil

  defp invocation_revision(%Invocation{tool_revision_id: revision_id, room_id: room_id}) do
    revision = Domain.get_tool_revision!(revision_id)
    if revision.room_id == room_id, do: revision, else: nil
  rescue
    _ -> nil
  end

  defp latest_failed_invocation(%Room{} = room) do
    case room.last_failed_invocation_id do
      id when is_binary(id) ->
        case fetch_invocation(id, room) do
          {:ok, %Invocation{effective_status: :verified_failure} = invocation} ->
            {:ok, invocation}

          _ ->
            {:error, "There is no verified failure to repair yet"}
        end

      _ ->
        {:error, "Run the seeded tool first; its visible postcondition must fail before repair"}
    end
  end

  defp latest_proposal(%Room{} = room) do
    with id when is_binary(id) <- room.active_repair_proposal_id,
         {:ok, proposal} <- fetch_proposal(id, room) do
      proposal
    else
      _ ->
        case Domain.list_repair_proposals!(
               query: [filter: [room_id: room.id], sort: [inserted_at: :desc], limit: 1]
             ) do
          [proposal | _] -> proposal
          [] -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp active_proposal(room) do
    case latest_proposal(room) do
      nil -> {:error, "No repair proposal is waiting for a human decision"}
      proposal -> {:ok, proposal}
    end
  end

  defp fetch_invocation(id, _room) when not is_binary(id),
    do: {:error, "invocation_id is required"}

  defp fetch_invocation(id, room) do
    invocation = Domain.get_invocation!(id)

    if invocation.room_id == room.id,
      do: {:ok, invocation},
      else: {:error, "invocation does not belong to this room"}
  rescue
    error -> {:error, readable_error(error)}
  end

  defp fetch_proposal(id, room) do
    proposal = Domain.get_repair_proposal!(id)

    if proposal.room_id == room.id,
      do: {:ok, proposal},
      else: {:error, "repair proposal does not belong to this room"}
  rescue
    _ -> {:error, "repair proposal is no longer available"}
  end

  defp register_browser_session(room, params, client_instance_id) do
    attrs = %{
      room_id: room.id,
      client_instance_id: client_instance_id,
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

  defp registry_attributes(params, room, mode) do
    observed_generation = value(params, "observed_generation")
    names = value(params, "observed_tool_names") || []
    contracts = value(params, "observed_contracts") || %{}
    revision = desired_revision!(room)
    expected_names = MapSet.new(@permanent_tool_names ++ [revision.name])
    observed_names = if is_list(names), do: MapSet.new(names), else: MapSet.new()
    contract_names = if is_map(contracts), do: MapSet.new(Map.keys(contracts)), else: MapSet.new()

    cond do
      observed_generation != room.desired_tool_generation ->
        {:error, "observed_generation must match the room's desired generation"}

      not is_list(names) or Enum.any?(names, &(not is_binary(&1))) or length(names) > 3 ->
        {:error, "observed_tool_names must be a list of names"}

      length(names) != MapSet.size(observed_names) ->
        {:error, "observed_tool_names must not contain duplicates"}

      not is_map(contracts) or
          Enum.any?(contracts, fn {name, digest} ->
            not is_binary(name) or not is_binary(digest) or
                not Regex.match?(@sha256_regex, digest)
          end) ->
        {:error, "observed_contracts must map tool names to SHA-256 digests"}

      contract_names != observed_names ->
        {:error, "observed contracts must exactly cover the observed tool names"}

      not MapSet.subset?(observed_names, expected_names) ->
        {:error, "observed registry contains a tool Patchbay does not own"}

      mode == :reconciled and observed_names != expected_names ->
        {:error, "reconciled registry must contain the complete desired Patchbay toolset"}

      MapSet.member?(observed_names, revision.name) and
          Map.get(contracts, revision.name) != revision.contract_sha256 ->
        {:error, "observed tool contract does not match the desired revision"}

      true ->
        {:ok,
         %{
           webmcp_supported: true,
           desired_generation: room.desired_tool_generation,
           observed_generation: observed_generation,
           observed_tool_names: names,
           observed_contracts: contracts,
           last_seen_at: DateTime.utc_now()
         }}
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
      "expected_ui_revision" => room.ui_revision,
      "ui_commit_required" => revision.handler_adapter == :apply_candidate_to_editor
    }
  end

  defp push_invocation_result(socket, invocation, revision) do
    push_event(
      socket,
      "patchbay:#{socket.assigns.room.id}:invocation_result",
      invocation_reply(invocation, revision, socket.assigns.room)
    )
  end

  defp push_publication_requested(socket, proposal, room) do
    revision = desired_revision!(room)

    push_event(socket, "patchbay:#{room.id}:publication_requested", %{
      "room_id" => room.id,
      "proposal_id" => proposal.id,
      "retire_before_register" => proposal.source_tool_revision_id,
      "revision" => revision_payload(revision)
    })
  end

  defp push_desired_toolset(socket) do
    room = socket.assigns.room
    revision = desired_revision!(room)

    push_event(socket, "patchbay:#{room.id}:desired_toolset", %{
      "room_id" => room.id,
      "generation" => room.desired_tool_generation,
      "permanent_tools" => ["get_patchbay_room_state", "verify_skill_uplift_goal"],
      "revisions" => [revision_payload(revision)]
    })
  rescue
    _ -> socket
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
        |> refresh(browser_session)
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

  defp demo_fallback? do
    Application.get_env(:patchbay, :demo_fallback, false) or
      System.get_env("PATCHBAY_DEMO_FALLBACK") in ["true", "1"]
  end

  defp invalidate_repair(socket) do
    case socket.assigns[:repair_token] do
      token when is_binary(token) ->
        {assign(socket, pending_operation: nil, repair_token: nil), {:repair, token}}

      _ ->
        {assign(socket, pending_operation: nil, repair_token: nil), nil}
    end
  end

  defp cancel_repair(socket, nil), do: socket
  defp cancel_repair(socket, key), do: cancel_async(socket, key, {:shutdown, :reset})

  defp repair_current?(socket, token) do
    socket.assigns[:pending_operation] == :repair and socket.assigns[:repair_token] == token
  end

  defp readable_error(%{__exception__: true} = error), do: Exception.message(error)
  defp readable_error({:shutdown, reason}), do: readable_error(reason)
  defp readable_error(reason) when is_binary(reason), do: reason
  defp readable_error(reason), do: inspect(reason)

  defp status_key(status) when is_atom(status), do: Atom.to_string(status)
  defp status_key(status) when is_binary(status), do: status
  defp status_key(status), do: inspect(status)

  defp status_label(status) do
    status
    |> status_key()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp status_class(status) do
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

  defp invocation_status_class(status) do
    case status_key(status) do
      "verified_success" -> "is-good"
      value when value in ["verified_failure", "errored", "cancelled"] -> "is-bad"
      _ -> "is-neutral"
    end
  end

  defp proposal_status_class(status) do
    case status_key(status) do
      value when value in ["published", "approved"] -> "is-good"
      value when value in ["rejected", "failed", "canary_failed"] -> "is-bad"
      _ -> "is-warn"
    end
  end

  defp observed_generation(nil), do: "—"
  defp observed_generation(%BrowserSession{observed_generation: nil}), do: "—"
  defp observed_generation(%BrowserSession{observed_generation: generation}), do: "G#{generation}"

  defp session_label(nil), do: "not connected"
  defp session_label(%BrowserSession{id: id}), do: short_id(id)

  defp short_id(value) when is_binary(value) do
    if byte_size(value) > 12, do: String.slice(value, 0, 8) <> "…", else: value
  end

  defp short_id(value), do: inspect(value)

  defp short_digest(value) when is_binary(value) do
    if byte_size(value) > 16, do: String.slice(value, 0, 12) <> "…", else: value
  end

  defp short_digest(_), do: "—"

  defp fallback_used?(%Invocation{handler_result: result}) when is_map(result) do
    provenance = map_value(result, :candidate_provenance, %{})
    map_value(provenance, :fallback_used, false) == true
  end

  defp fallback_used?(_), do: false

  defp proposal_fallback?(proposal) do
    is_binary(proposal.model) and String.contains?(String.downcase(proposal.model), "fallback")
  end

  defp diff_entries(diff) when is_map(diff) do
    diff
    |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
  end

  defp diff_entries(_), do: []

  defp diff_from(diff) when is_map(diff), do: map_value(diff, :from, nil)
  defp diff_from(_), do: nil

  defp diff_to(diff) when is_map(diff), do: map_value(diff, :to, nil)
  defp diff_to(_), do: nil

  defp format_value(value) when is_binary(value), do: value
  defp format_value(nil), do: "—"
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)

  defp format_value(value) do
    value
    |> printable_value()
    |> Jason.encode!(pretty: true)
  rescue
    _ -> inspect(value)
  end

  defp format_map(value) when is_map(value), do: format_value(value)
  defp format_map(value), do: inspect(value)

  defp printable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp printable_value(value) when is_list(value), do: Enum.map(value, &printable_value/1)

  defp printable_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), printable_value(item)} end)
  end

  defp printable_value(value), do: value

  defp canary_passed?(proposal) do
    map_value(proposal.canary_result, :passed, false) == true
  end

  defp canary_checks(result) when is_map(result) do
    result
    |> map_value(:checks, %{})
    |> Enum.sort_by(fn {name, _passed} -> to_string(name) end)
  end

  defp canary_checks(_), do: []

  defp event_label(kind) do
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
      tool_revision_observed: "Tool revision observed",
      goal_verified: "Goal verified",
      platform_error: "Platform error"
    }
    |> Map.get(kind, status_label(kind))
  end

  defp timeline_detail(%RoomEvent{payload: payload}) when is_map(payload) do
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

  defp timeline_detail(_), do: "Recorded in room evidence"

  defp relative_time(%DateTime{} = inserted_at) do
    seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> Calendar.strftime(inserted_at, "%H:%M:%S")
    end
  end

  defp relative_time(_), do: ""

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp map_value(_map, _key, default), do: default
end
