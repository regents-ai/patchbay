defmodule PatchbayWeb.WebMCP.RoomLiveTest do
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Digest, Fixtures}

  setup %{conn: conn} do
    room = Domain.create_seeded_room!()

    Fixtures.revision_attributes(room.id)
    |> Map.delete(:contract_sha256)
    |> Domain.create_tool_revision!()

    previous_fallback = Application.get_env(:patchbay, :demo_fallback)
    Application.put_env(:patchbay, :demo_fallback, true)

    on_exit(fn ->
      if is_nil(previous_fallback) do
        Application.delete_env(:patchbay, :demo_fallback)
      else
        Application.put_env(:patchbay, :demo_fallback, previous_fallback)
      end
    end)

    %{conn: conn, room: room}
  end

  test "renders the seeded room with stable editor and state identifiers", %{conn: conn} do
    {:ok, view, html} = live(conn, "/webmcp/rooms/skill-uplift")

    assert html =~ "Skill Uplift Studio"
    assert has_element?(view, "#patchbay-source-editor")
    assert has_element?(view, "#patchbay-candidate-editor")
    assert has_element?(view, "#patchbay-room-state[data-ui-revision=\"0\"]")
    assert has_element?(view, "[id^=patchbay-webmcp-]")
    assert html =~ "Candidate editor"
    assert html =~ "empty"
  end

  test "updates source digest through the same room page", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    source = room.source_markdown <> "\n\n## Local note\n"

    html = render_submit(view |> form("#patchbay-source-form"), %{"source_markdown" => source})

    assert html =~ Digest.sha256(source)
    assert Domain.get_room_by_id!(room.id).source_sha256 == Digest.sha256(source)
  end

  test "shows raw success beside effective visible failure and fallback provenance", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)

    html =
      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "request_uuid" => Ash.UUID.generate(),
        "arguments" => %{"instructions" => "clarify the workflow"}
      })

    assert html =~ "Raw handler result"
    assert html =~ "success"
    assert html =~ "Visible postcondition failed"
    assert html =~ "CANDIDATE_EMPTY"
    assert html =~ "Demo fallback used"
    assert Domain.get_room_by_id!(room.id).status == :failed
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
  end

  test "runs repair, human approval, observed generation, retry, and reset on one page", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_click(view, "request_repair")
    html = render_async(view)

    assert html =~ "CONTRACT DIFF"
    assert html =~ "DETERMINISTIC CANARY"
    assert html =~ "Approve &amp; hot-swap"

    proposal =
      Domain.list_repair_proposals!(
        query: [filter: [room_id: room.id], sort: [inserted_at: :desc], limit: 1]
      )
      |> List.first()

    assert proposal.status == :ready_for_approval

    html = render_click(view, "approve_repair", %{"approved_by" => "forged-browser-value"})
    assert html =~ "Generation 2"
    assert html =~ "Publication requested"

    v1 =
      Domain.list_tool_revisions!(query: [filter: [room_id: room.id, generation: 1], limit: 1])
      |> List.first()

    assert has_element?(view, "#patchbay-invocation-evidence code", v1.name)

    assert Domain.get_repair_proposal!(proposal.id).approved_by == "owner"

    v2 = Domain.get_tool_revision!(proposal.candidate_tool_revision_id)
    proposal_id = proposal.id

    publication_event = "patchbay:#{room.id}:publication_requested"

    assert_push_event(view, ^publication_event, %{"proposal_id" => ^proposal_id})

    html =
      render_hook(view, "webmcp_toolchange_observed", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "observed_generation" => 2,
        "observed_tool_names" => [v2.name],
        "observed_contracts" => %{v2.name => v2.contract_sha256}
      })

    assert html =~ "toolchange observed"
    assert html =~ "Observed G2"

    html = render_click(view, "retry_original_goal")

    assert html =~ "Verification passed"
    assert html =~ Digest.sha256(Fixtures.improved_markdown())
    assert html =~ "ready"
    assert Domain.get_room_by_id!(room.id).status == :verified

    html = render_click(view, "reset_demo")
    assert html =~ "Generation 1"
    assert html =~ "Candidate editor"
    assert html =~ "empty"
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
    assert Domain.get_room_by_id!(room.id).status == :ready
    reset_event = "patchbay:#{room.id}:reset_browser_registry"
    room_id = room.id
    assert_push_event(view, ^reset_event, %{"room_id" => ^room_id})
  end

  test "reset invalidates a stale repair callback", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_click(view, "request_repair")

    {:ok, pending_socket} = Phoenix.LiveView.Debug.socket(view.pid)
    repair_token = pending_socket.assigns.repair_token
    assert is_binary(repair_token)

    html = render_click(view, "reset_demo")

    assert html =~ "Generation 1"
    {:ok, reset_socket} = Phoenix.LiveView.Debug.socket(view.pid)
    assert reset_socket.assigns.pending_operation == nil
    assert reset_socket.assigns.repair_token == nil

    assert {:noreply, callback_socket} =
             PatchbayWeb.WebMCP.RoomLive.Show.handle_async(
               {:repair, repair_token},
               {:ok, {:repair_result, repair_token, {:ok, :stale}}},
               reset_socket
             )

    assert callback_socket.assigns.room.status == :ready
    assert callback_socket.assigns.pending_operation == nil
    assert callback_socket.assigns.repair_token == nil
  end

  test "discloses a browser registry error instead of accepting a forged room event", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")

    html =
      render_hook(view, "webmcp_registry_reconciled", %{
        "room_id" => Ash.UUID.generate(),
        "observed_generation" => 1,
        "observed_tool_names" => [],
        "observed_contracts" => %{}
      })

    assert html =~ "event belongs to another room"
    assert Domain.list_room_events!(query: [filter: [room_id: room.id], limit: 1]) == []
  end

  test "rejects post-state evidence from a different browser session", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    first_session = bootstrap(view, room)
    invoke_v1(view, room, first_session)

    invocation =
      Domain.list_invocations!(
        query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
      )
      |> List.first()

    second_session = bootstrap(view, room)

    events_before =
      Domain.list_room_events!(query: [filter: [room_id: room.id], sort: [sequence: :asc]])

    html =
      render_hook(view, "webmcp_poststate_observed", %{
        "room_id" => room.id,
        "browser_session_id" => second_session.id,
        "invocation_id" => invocation.id,
        "post_state" => %{}
      })

    assert html =~ "post-state observation must come from the invocation browser session"

    assert length(Domain.list_room_events!(query: [filter: [room_id: room.id]])) ==
             length(events_before)
  end

  defp bootstrap(view, room) do
    client_instance_id = Ash.UUID.generate()

    html =
      render_hook(view, "webmcp_bootstrap", %{
        "room_id" => room.id,
        "client_instance_id" => client_instance_id,
        "webmcp_supported" => true,
        "user_agent_digest" => Digest.sha256("test-browser")
      })

    assert html =~ "WebMCP connected"

    Domain.list_browser_sessions!(
      query: [filter: [room_id: room.id], sort: [connected_at: :desc], limit: 1]
    )
    |> List.first()
  end

  defp invoke_v1(view, room, session) do
    html =
      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "request_uuid" => Ash.UUID.generate(),
        "arguments" => %{"instructions" => "clarify the workflow"}
      })

    assert html =~ "Visible postcondition failed"
  end
end
