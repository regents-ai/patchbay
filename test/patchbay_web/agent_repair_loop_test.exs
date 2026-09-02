defmodule PatchbayWeb.AgentRepairLoopTest do
  @moduledoc """
  The whole loop, driven with nothing an agent would not actually be holding.

  Everything the report is filed with comes out of the result the page handed
  back for the call. No digest is computed here, because a language model
  calling these tools could not compute one either.
  """

  # The worker reads application settings, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PatchbayAgent
  alias Patchbay.Forum.RepairAttempt
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.Digest

  setup do
    put_setting(:demo_fallback, true)
    put_setting(:agent_repairs, true)

    :ok
  end

  test "an agent can get a verified repair using only the tool result it received", %{conn: conn} do
    room = Domain.create_seeded_room!("room-#{System.unique_integer([:positive])}")
    conn = get(conn, ~p"/webmcp/rooms/#{room.slug}")
    {:ok, view, _html} = live(conn)
    session = bootstrap(view, room)

    result = call_the_broken_tool(view, room, session)

    # Everything the agent is told about what to do next, and the one value it
    # needs to do it.
    assert result["effective_status"] == "verified_failure"

    assert result["next_action"] ==
             "Call report_tool_problem with receipt set to the patchbay_receipt value in this result."

    assert %{"receipt" => receipt} = result["report_this_call"]
    assert receipt == result["patchbay_receipt"]

    # The report carries the receipt and the agent's own words. Nothing else.
    filed =
      post_json(conn, "/forum/reports", %{
        "receipt" => receipt,
        "note" => "It said it worked, but the page did nothing."
      })

    assert %{"report_id" => report_id, "verified" => true, "receipt_status" => "verified"} =
             json_response(filed, 201)

    report = Ash.get!(Report, report_id, load: [tool: :site])
    revision = desired_revision(room)

    assert report.verified
    assert report.tool.site.origin == RoomMirror.origin()
    assert report.tool.name == revision.name
    assert report.tool.contract_sha256 == revision.contract_sha256
    assert report.arguments_sha256 == latest_invocation(room).arguments_sha256

    # One pass of the worker that reads the board.
    assert {:ok, %RepairAttempt{} = attempt} = PatchbayAgent.sweep()
    assert attempt.status == :published
    assert attempt.report_id == report.id

    repaired = Domain.get_room_by_id!(room.id)
    assert repaired.desired_tool_generation == 2
    assert desired_revision(repaired).name == "uplift_current_skill_v2"

    [reply] = Forum.list_replies_for_report!(report.id).results
    assert reply.note =~ "Please retry with uplift_current_skill_v2."
  end

  # One call to the tool the page is offering, taken to its visible verdict, and
  # answered with the same map the browser receives.
  defp call_the_broken_tool(view, room, session) do
    revision = desired_revision(room)

    render_hook(view, "webmcp_invocation_begin", %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "request_uuid" => Ash.UUID.generate(),
      "tool_name" => revision.name,
      "contract_sha256" => revision.contract_sha256,
      "arguments" => %{"instructions" => "make the greeting warmer"}
    })

    invocation = latest_invocation(room)

    render_hook(view, "webmcp_execute", %{
      "invocation_id" => invocation.id,
      "invocation_epoch" => invocation_epoch(view)
    })

    render_async(view, 2_000)
    observe_post_state(view, room, session)
  end

  # The page reports what it is showing and is answered with the tool result.
  # The observation is run twice: once through the live page, which is what
  # moves the room on, and once directly, which is the only way a test can read
  # the reply the browser is handed. Verification has already happened by then,
  # so the second call reads the record rather than writing it.
  defp observe_post_state(view, room, session) do
    current = Domain.get_room_by_id!(room.id)

    params = %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "invocation_id" => latest_invocation(room).id,
      "post_state" => %{
        "ui_revision" => current.ui_revision,
        "source" => %{"present" => true, "sha256" => current.source_sha256},
        "candidate" => %{
          "present" => is_binary(current.candidate_markdown),
          "sha256" => current.candidate_sha256
        }
      }
    }

    render_hook(view, "webmcp_poststate_observed", params)

    {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)

    {:reply, reply, _socket} =
      PatchbayWeb.WebMCP.RoomLive.Show.handle_event("webmcp_poststate_observed", params, socket)

    reply
  end

  defp bootstrap(view, room) do
    html =
      render_hook(view, "webmcp_bootstrap", %{
        "room_id" => room.id,
        "client_instance_id" => Ash.UUID.generate(),
        "webmcp_supported" => true,
        "user_agent_digest" => Digest.sha256("test-browser")
      })

    assert html =~ "WebMCP connected"

    Domain.list_browser_sessions!(
      query: [filter: [room_id: room.id], sort: [connected_at: :desc], limit: 1]
    )
    |> List.first()
  end

  defp desired_revision(room) do
    Domain.list_tool_revisions!(
      query: [
        filter: [room_id: room.id, generation: room.desired_tool_generation, status: :desired],
        limit: 1
      ]
    )
    |> List.first()
  end

  defp latest_invocation(room) do
    Domain.list_invocations!(
      query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
    )
    |> List.first()
  end

  defp invocation_epoch(view) do
    {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)
    socket.assigns.invocation_epoch
  end

  defp post_json(conn, path, params) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp put_setting(key, value) do
    previous = Application.get_env(:patchbay, key)
    Application.put_env(:patchbay, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:patchbay, key),
        else: Application.put_env(:patchbay, key, previous)
    end)
  end
end
