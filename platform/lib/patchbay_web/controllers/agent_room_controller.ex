defmodule PatchbayWeb.AgentRoomController do
  @moduledoc "Signed room operations retain the real page session and visible-state verifier."
  use PatchbayWeb, :controller
  alias Patchbay.Agents.RoomAccess
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{InvocationRunner, RepairPlanner, Room}

  def invoke(conn, params),
    do:
      operation(conn, params, fn actor, room, session ->
        revision = Ash.load!(room, :desired_tool_revision).desired_tool_revision

        if params["tool_name"] != revision.name or
             params["contract_sha256"] != revision.contract_sha256,
           do: raise(ArgumentError, "stale tool")

        {:ok, request_uuid} = Ecto.UUID.cast(params["request_uuid"])
        true = is_map(params["pre_state"])

        invocation =
          InvocationRunner.begin!(room, session, revision, params["arguments"],
            actor: actor,
            request_uuid: request_uuid,
            invocation_epoch: room.invocation_epoch,
            pre_state: params["pre_state"]
          )

        invocation = InvocationRunner.execute!(invocation, actor: actor)

        %{
          invocation_id: invocation.id,
          request_uuid: invocation.request_uuid,
          receipt: invocation.receipt,
          effective_status: invocation.effective_status,
          handler_result: invocation.handler_result,
          ui_commit_required: invocation.handler_result["applied"] == true,
          expected_ui_revision: invocation.handler_result["ui_revision"]
        }
      end)

  def observe(conn, params),
    do:
      operation(conn, params, fn actor, room, session ->
        invocation = owned_invocation!(params["id"], actor, room, session)
        true = is_map(params["post_state"])
        verified = InvocationRunner.verify!(invocation, params["post_state"], actor: actor)

        %{
          invocation_id: verified.id,
          receipt: verified.receipt,
          effective_status: verified.effective_status,
          failure_code: verified.failure_code
        }
      end)

  def cancel(conn, params),
    do:
      operation(conn, params, fn actor, room, session ->
        {:ok, invocation} =
          Patchbay.Repo.transaction(fn ->
            invocation = owned_invocation!(params["id"], actor, room, session)
            locked_room = Domain.get_room_for_update!(room.id)
            invocation = Domain.get_invocation_for_update!(invocation.id)
            RoomAccess.lock!(actor, locked_room, invocation)
            InvocationRunner.cancel!(invocation)
          end)

        %{invocation_id: invocation.id, effective_status: invocation.effective_status}
      end)

  def repair(conn, params),
    do:
      operation(conn, params, fn actor, room, _session ->
        # The existing planner performs inference outside its committing transaction
        # and rechecks this actor when it saves the proposal. It never approves it.
        invocation = Domain.get_invocation!(room.last_failed_invocation_id)
        proposal = RepairPlanner.propose!(invocation, actor: actor)
        %{proposal_id: proposal.id, status: proposal.status, requires_owner_approval: true}
      end)

  defp operation(conn, params, fun) do
    actor = conn.assigns.agent_actor

    with {:ok, room} <- Domain.get_room_by_slug(params["slug"]),
         true <- not is_nil(room),
         {:ok, evidence} <-
           Phoenix.Token.verify(PatchbayWeb.Endpoint, "agent-room-page", params["page_evidence"],
             max_age: 3600
           ),
         true <-
           evidence.room_id == room.id and evidence.invocation_epoch == room.invocation_epoch,
         {:ok, session} <- Domain.get_browser_session(evidence.browser_session_id),
         true <-
           session.room_id == room.id and
             session.client_instance_id == evidence.client_instance_id and
             is_nil(session.disconnected_at) do
      {:ok, :ok} =
        Patchbay.Repo.transaction(fn ->
          RoomAccess.lock!(actor, Domain.get_room_for_update!(room.id))
        end)

      result = fun.(actor, room, session)

      Phoenix.PubSub.broadcast(
        Patchbay.PubSub,
        Room.topic(room.id),
        {:agent_room_changed, room.id}
      )

      json(conn, result)
    else
      _ ->
        refused(
          conn,
          :forbidden,
          "Open the owner's room and prepare this request there. The current page attachment is required."
        )
    end
  rescue
    _ in Ash.Error.Forbidden ->
      refused(conn, :forbidden, "Current pairing and the owner's room rights are required.")

    _ ->
      refused(
        conn,
        :unprocessable_entity,
        "The room state or request changed. Read the current page, then prepare fresh proof. No success is claimed."
      )
  end

  defp owned_invocation!(id, actor, room, session) do
    invocation = Domain.get_invocation!(id)

    if invocation.room_id != room.id or invocation.browser_session_id != session.id or
         invocation.acting_agent_id != actor.id or invocation.pairing_id != actor.pairing_id,
       do: raise(Ash.Error.Forbidden, errors: [])

    invocation
  end

  defp refused(conn, status, hint),
    do:
      conn
      |> put_status(status)
      |> json(
        PatchbayWeb.ApiError.body("room_request_refused", "The room operation was refused.", hint)
      )
end
